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
    const { data: members, error: membersError } = await serviceClient
      .from('event_series_membership')
      .select('event_id, position, event:events(id, creator_id, max_capacity, registration_deadline, external_registration_url, lifecycle_status, publication_status)')
      .eq('series_id', seriesId)
      .order('position', { ascending: true })

    if (membersError || !members || members.length === 0) {
      return errorResponse('not_found', 'Series has no member events', 404)
    }

    // 4. Validate all events are accessible
    const firstMember = members[0] as Record<string, unknown>
    const events = (firstMember.event ? members.map((m: Record<string, unknown>) => m.event) : []) as Array<Record<string, unknown>>

    for (const event of events) {
      if (!event || !event.id) {
        return errorResponse('not_found', 'One or more member events not found', 404)
      }

      if ((event as any).external_registration_url) {
        return errorResponse('external_registration', 'One or more events use external registration', 400)
      }

      if ((event as any).lifecycle_status === 'cancelled' || (event as any).publication_status === 'closed') {
        return errorResponse('event_closed', `Event ${event.id} is not open for registration`, 400)
      }

      if ((event as any).registration_deadline && new Date((event as any).registration_deadline) < new Date()) {
        return errorResponse('registration_closed', `Registration deadline has passed for event ${event.id}`, 400)
      }

      if ((event as any).creator_id === user.id) {
        return errorResponse('host_cannot_register', `You are the host of event ${event.id}`, 400)
      }
    }

    // 5. Validate capacity for all events (for whole_series_registration)
    // For each event, check if there is available capacity
    for (const event of events) {
      const maxCap = (event as any).max_capacity
      if (maxCap != null) {
        const { count: approvedCount } = await serviceClient
          .from('event_registrations')
          .select('id', { count: 'exact', head: true })
          .eq('event_id', (event as any).id)
          .neq('status', 'cancelled')

        if (approvedCount != null && approvedCount >= maxCap) {
          return errorResponse('capacity_exhausted', `Event ${(event as any).id} is at full capacity`, 400)
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

    // 7. Create series registration
    const { data: seriesRegistration, error: regError } = await serviceClient
      .from('event_series_registrations')
      .insert({
        series_id: seriesId,
        profile_id: user.id,
        status: 'approved',
        whole_series_registration: true,
      })
      .select('id')
      .single()

    if (regError || !seriesRegistration) {
      return errorResponse('internal_error', 'Failed to create series registration', 500)
    }

    // 8. Create individual event registrations for each member event
    let failedCount = 0
    const registrationIds: string[] = []

    for (const event of events) {
      const { data: eventReg, error: eventRegError } = await serviceClient
        .from('event_registrations')
        .insert({
          event_id: (event as any).id,
          profile_id: user.id,
          status: 'approved',
        })
        .select('id')
        .single()

      if (eventRegError) {
        failedCount++
        console.error(`Failed to create registration for event ${(event as any).id}:`, eventRegError)
      } else {
        registrationIds.push(eventReg.id)
      }
    }

    // If any individual registration failed, still succeed but log the warning
    console.log(`Series registration ${seriesRegistration.id}: ${registrationIds.length}/${events.length} event registrations created`)

    return jsonResponse({
      success: true,
      registration_id: seriesRegistration.id,
      event_registration_count: registrationIds.length,
      total_events: events.length,
    }, 200)

  } catch (err) {
    console.error('register-for-event-series error:', err)
    return errorResponse('internal_error', 'An unexpected error occurred', 500)
  }
})