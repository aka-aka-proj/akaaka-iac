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

interface SeriesMemberEvent {
  event_id: string
  position: number
}

interface OwnedEvent {
  id: string
  series_member_position: number | null
}

interface CreateSeriesPayload {
  title: string
  description?: string
  is_whole_series_required?: boolean
  member_events: SeriesMemberEvent[]
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
      console.error('create-event-series missing Supabase environment')
      return errorResponse('internal_error', 'Server configuration is incomplete', 500)
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    })
    const { data: { user }, error: authError } = await userClient.auth.getUser()
    if (authError || !user) return errorResponse('unauthorized', 'Invalid or expired token', 401)

    const body = await req.json() as CreateSeriesPayload
    const { title, description, is_whole_series_required, member_events } = body

    if (!title?.trim()) return errorResponse('validation_error', 'title is required', 400)
    if (!Array.isArray(member_events) || member_events.length < 2) {
      return errorResponse('validation_error', 'At least 2 member events are required', 400)
    }

    const positions = member_events.map((member) => member.position)
    if (positions.some((position) => !Number.isInteger(position) || position < 1) || new Set(positions).size !== positions.length) {
      return errorResponse('validation_error', 'member event positions must be unique positive integers', 400)
    }

    const serviceClient = createClient(supabaseUrl, serviceRoleKey)

    // Verify caller owns all member events
    const { data: ownedEvents, error: ownedError } = await serviceClient
      .from('events')
      .select('id, lifecycle_status, series_member_position')
      .in('id', member_events.map((m) => m.event_id))
      .eq('creator_id', user.id)

    if (ownedError) return errorResponse('internal_error', 'Failed to verify event ownership', 500)
    if (!ownedEvents || ownedEvents.length !== member_events.length) {
      return errorResponse('forbidden', 'You must be the creator of all member events', 403)
    }
    const previousPositions = new Map((ownedEvents as OwnedEvent[]).map((event) => [event.id, event.series_member_position]))
    if (ownedEvents.some((event) => event.lifecycle_status !== 'draft')) {
      return errorResponse('validation_error', 'Only draft events can be added to a new activity series', 400)
    }

    // Check no event already belongs to another series
    for (const me of member_events) {
      const { data: existingMembership, error: membershipLookupError } = await serviceClient
        .from('event_series_membership')
        .select('id')
        .eq('event_id', me.event_id)
        .maybeSingle()

      if (membershipLookupError) return errorResponse('internal_error', 'Failed to verify event series membership', 500)
      if (existingMembership) {
        return errorResponse('conflict_error', `Event ${me.event_id} already belongs to a series`, 409)
      }
    }

    // Create the series
    const { data: series, error: seriesError } = await serviceClient
      .from('event_series')
      .insert({
        creator_id: user.id,
        title: title.trim(),
        description: description?.trim() ?? null,
        is_whole_series_required: is_whole_series_required ?? false,
        lifecycle_status: 'draft',
      })
      .select('id')
      .single()

    if (seriesError || !series) {
      return errorResponse('internal_error', 'Failed to create series', 500)
    }

    const seriesId = series.id

    // Create membership entries
    const membershipValues = member_events.map((me) => ({
      series_id: seriesId,
      event_id: me.event_id,
      position: me.position,
    }))

    const { error: memberError } = await serviceClient
      .from('event_series_membership')
      .insert(membershipValues)

    if (memberError) {
      // Rollback: delete the series
      await serviceClient.from('event_series').delete().eq('id', seriesId)
      return errorResponse('internal_error', 'Failed to add member events to series', 500)
    }

    // Update events.series_member_position for quick reference
    for (const me of member_events) {
      const { error: positionError } = await serviceClient
        .from('events')
        .update({ series_member_position: me.position })
        .eq('id', me.event_id)
      if (positionError) {
        for (const member of member_events) {
          await serviceClient.from('events')
            .update({ series_member_position: previousPositions.get(member.event_id) })
            .eq('id', member.event_id)
        }
        await serviceClient.from('event_series').delete().eq('id', seriesId)
        return errorResponse('internal_error', 'Failed to synchronize member event positions', 500)
      }
    }

    return jsonResponse({
      success: true,
      series_id: seriesId,
      member_count: member_events.length,
    }, 200)

  } catch (err) {
    console.error('create-event-series error:', err)
    return errorResponse('internal_error', 'An unexpected error occurred', 500)
  }
})
