import { createClient } from '@supabase/supabase-js'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

function errorResponse(code: string, message: string, status: number): Response {
  return jsonResponse({ error: { code, message } }, status)
}

interface SeriesEventRow {
  id: string
  creator_id: string
  max_capacity: number | null
  registration_deadline: string | null
  external_registration_url: string | null
  registration_form_config: unknown
  visibility_settings: unknown
  lifecycle_status: string
  publication_status: string
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return errorResponse('validation_error', 'Only POST is supported', 400)

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return errorResponse('unauthorized', 'Missing authorization header', 401)

    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      console.error('register-for-event-series missing Supabase environment')
      return errorResponse('internal_error', 'Server configuration is incomplete', 500)
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    })
    const { data: { user }, error: authError } = await userClient.auth.getUser()
    if (authError || !user) return errorResponse('unauthorized', 'Invalid or expired token', 401)

    const body = await req.json() as {
      series_id?: string
      form_responses?: Record<string, unknown>
    }
    const seriesId = body.series_id
    if (!seriesId) return errorResponse('validation_error', 'series_id is required', 400)

    const serviceClient = createClient(supabaseUrl, serviceRoleKey)

    // 1. Fetch the series
    const { data: series, error: seriesError } = await serviceClient
      .from('event_series')
      .select('*')
      .eq('id', seriesId)
      .single()

    if (seriesError || !series) {
      return errorResponse('not_found', 'Series not found', 404)
    }

    if (series.lifecycle_status !== 'published') {
      return errorResponse('registration_closed', 'Series is not accepting registrations', 400)
    }

    if (series.creator_id === user.id) {
      return errorResponse('host_cannot_register', 'Series host cannot register for their own series', 400)
    }

    // 2. Check duplicate registration
    const { data: existingReg } = await serviceClient
      .from('event_series_registrations')
      .select('id, status')
      .eq('series_id', seriesId)
      .eq('profile_id', user.id)
      .eq('whole_series_registration', true)
      .neq('status', 'cancelled')
      .maybeSingle()

    if (existingReg) {
      return errorResponse('duplicate_registration', 'You are already registered for this series', 400)
    }

    // 3. Fetch all member events
    const { data: rawMembers, error: membersError } = await serviceClient
      .from('event_series_membership')
      .select('event_id, position, event:events(id, creator_id, max_capacity, registration_deadline, external_registration_url, registration_form_config, visibility_settings, lifecycle_status, publication_status)')
      .eq('series_id', seriesId)
      .order('position', { ascending: true })

    if (membersError || !rawMembers || rawMembers.length === 0) {
      return errorResponse('not_found', 'Series has no member events', 404)
    }

    // 4. Validate all events are accessible
    const members = (rawMembers as unknown) as Array<{
      event_id: string
      position: number
      event: unknown[]
    }>
    const events: SeriesEventRow[] = []
    for (const member of members) {
      const nested = Array.isArray(member.event) ? member.event[0] : member.event
      if (nested && typeof nested === 'object') {
        events.push(nested as SeriesEventRow)
      }
    }

    if (events.length === 0) {
      return errorResponse('not_found', 'Member events could not be loaded', 404)
    }

    for (const event of events) {
      if (event.external_registration_url) {
        return errorResponse('external_registration', 'One or more events use external registration', 400)
      }
      if (event.lifecycle_status === 'cancelled' || event.publication_status === 'closed') {
        return errorResponse('event_closed', `Event ${event.id} is not open for registration`, 400)
      }
      if (event.registration_deadline && new Date(event.registration_deadline) < new Date()) {
        return errorResponse('registration_closed', `Registration deadline has passed for event ${event.id}`, 400)
      }
      if (event.creator_id === user.id) {
        return errorResponse('host_cannot_register', `You are the host of event ${event.id}`, 400)
      }

      const visibilityType = typeof event.visibility_settings === 'object' && event.visibility_settings !== null
        ? (event.visibility_settings as { type?: unknown }).type
        : undefined
      if (visibilityType === 'private') {
        return errorResponse('forbidden', `Event ${event.id} is private and cannot be registered through a public series`, 403)
      }
      if (visibilityType === 'connections_only') {
        const { data: followsHost, error: followsHostError } = await serviceClient
          .from('user_follows')
          .select('follower_id')
          .eq('follower_id', user.id)
          .eq('followed_id', event.creator_id)
          .maybeSingle()
        const { data: hostFollowsUser, error: hostFollowsUserError } = await serviceClient
          .from('user_follows')
          .select('follower_id')
          .eq('follower_id', event.creator_id)
          .eq('followed_id', user.id)
          .maybeSingle()
        if (followsHostError || hostFollowsUserError) return errorResponse('internal_error', 'Failed to verify event visibility', 500)
        if (!followsHost || !hostFollowsUser) return errorResponse('forbidden', `You are not connected to the host of event ${event.id}`, 403)
      }

      if (event.registration_form_config) {
        const formResponses = body.form_responses ?? {}
        const config = Array.isArray(event.registration_form_config)
          ? event.registration_form_config as Array<{ id: string; required?: boolean; type?: string; options?: string[] }>
          : []
        for (const field of config) {
          const value = formResponses[field.id]
          if (field.required && (value === undefined || value === null || value === '' || value === false)) {
            return errorResponse('form_validation_error', `Required field '${field.id}' is missing`, 400)
          }
          if (field.type === 'select' && field.options && value !== undefined && value !== null && value !== '') {
            if (!field.options.includes(value as string)) {
              return errorResponse('form_validation_error', `Invalid value for field '${field.id}'`, 400)
            }
          }
        }
      }
    }

    // 5. Validate capacity for all events (for whole_series_registration)
    for (const event of events) {
      if (event.max_capacity != null) {
        const { count: approvedCount } = await serviceClient
          .from('event_registrations')
          .select('id', { count: 'exact', head: true })
          .eq('event_id', event.id)
          .in('status', ['approved', 'pending', 'waitlisted', 'cancellation_pending', 'cancellation_rejected'])

        if (approvedCount != null && approvedCount >= event.max_capacity) {
          return errorResponse('capacity_exhausted', `Event ${event.id} is at full capacity`, 400)
        }
      }
    }

    // 6. Block check (bidirectional against the series creator)
    const { data: blocks } = await serviceClient
      .from('blocks')
      .select('blocker_id, blocked_id')
      .or(`and(blocker_id.eq.${user.id},blocked_id.eq.${series.creator_id}),and(blocker_id.eq.${series.creator_id},blocked_id.eq.${user.id})`)

    if (blocks && blocks.length > 0) {
      const block = blocks[0]
      const message = block.blocker_id === user.id
        ? 'You have blocked this series host.'
        : 'This series host has blocked you.'
      return errorResponse('blocked', message, 403)
    }

    // Recheck capacity and perform every write under one database transaction.
    const { data: rawAtomicRegistration, error: atomicError } = await serviceClient.rpc(
      'register_event_series_atomic',
      { p_series_id: seriesId, p_profile_id: user.id, p_form_responses: body.form_responses ?? {} },
    ).single()
    const atomicRegistration = rawAtomicRegistration as unknown as {
      registration_id: string
      event_registration_count: number
    } | null
    if (atomicError || !atomicRegistration) {
      console.error('Failed to atomically register for series:', atomicError)
      const isCapacityRace = atomicError?.message?.includes('capacity')
      return errorResponse(
        isCapacityRace ? 'capacity_exhausted' : 'internal_error',
        isCapacityRace ? 'The series changed while you were registering. Please try again.' : 'Failed to register for every member event',
        isCapacityRace ? 409 : 500,
      )
    }

    console.log(`Series registration ${atomicRegistration.registration_id}: ${atomicRegistration.event_registration_count}/${events.length} event registrations created`)

    return jsonResponse({
      success: true,
      registration_id: atomicRegistration.registration_id,
      event_registration_count: atomicRegistration.event_registration_count,
      total_events: events.length,
    }, 200)

  } catch (err) {
    console.error('register-for-event-series error:', err)
    return errorResponse('internal_error', 'An unexpected error occurred', 500)
  }
})
