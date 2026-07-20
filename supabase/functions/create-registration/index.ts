import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

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

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return jsonResponse({ error: 'unauthorized', message: 'Missing authorization header' }, 401)
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    })

    const {
      data: { user },
      error: authError,
    } = await userClient.auth.getUser()

    if (authError || !user) {
      return jsonResponse({ error: 'unauthorized', message: 'Invalid or expired token' }, 401)
    }

    const body = (await req.json()) as { event_id?: string }
    const eventId = body.event_id

    if (!eventId) {
      return jsonResponse({ error: 'invalid', message: 'event_id is required' }, 400)
    }

    const serviceClient = createClient(supabaseUrl, serviceRoleKey)

    // 1. Fetch event
    const { data: event, error: eventError } = await serviceClient
      .from('events')
      .select('id, creator_id, max_capacity, registration_deadline')
      .eq('id', eventId)
      .single()

    if (eventError || !event) {
      return jsonResponse({ error: 'not_found', message: 'Event not found' }, 404)
    }

    // 2. Host cannot register for own event
    if (event.creator_id === user.id) {
      return jsonResponse({ error: 'host_cannot_register', message: 'Event host cannot register for their own event' }, 400)
    }

    // 3. Registration deadline check
    if (event.registration_deadline && new Date(event.registration_deadline) < new Date()) {
      return jsonResponse({ error: 'registration_closed', message: 'Registration deadline has passed' }, 400)
    }

    // 4. Block check (bidirectional)
    const { data: blocks } = await serviceClient
      .from('blocks')
      .select('blocker_id')
      .or(`and(blocker_id.eq.${user.id},blocked_id.eq.${event.creator_id}),and(blocker_id.eq.${event.creator_id},blocked_id.eq.${user.id})`)

    if (blocks && blocks.length > 0) {
      return jsonResponse({ error: 'blocked', message: 'You are unable to register for this event' }, 403)
    }

    // 5. Check existing active registration
    const { data: existing } = await serviceClient
      .from('event_registrations')
      .select('id, status')
      .eq('event_id', eventId)
      .eq('profile_id', user.id)
      .neq('status', 'cancelled')
      .maybeSingle()

    if (existing) {
      return jsonResponse({ error: 'already_registered', message: 'You already have an active registration for this event' }, 400)
    }

    // 6. Determine status: pending or waitlisted
    let status = 'pending'
    let waitlistPosition: number | null = null

    if (event.max_capacity) {
      const { count: approvedCount } = await serviceClient
        .from('event_registrations')
        .select('id', { count: 'exact', head: true })
        .eq('event_id', eventId)
        .in('status', ['approved', 'pending'])

      if ((approvedCount ?? 0) >= event.max_capacity) {
        // Get next waitlist position
        const { data: maxWaitlist } = await serviceClient
          .from('event_registrations')
          .select('waitlist_position')
          .eq('event_id', eventId)
          .eq('status', 'waitlisted')
          .order('waitlist_position', { ascending: false })
          .limit(1)
          .maybeSingle()

        waitlistPosition = (maxWaitlist?.waitlist_position ?? 0) + 1
        status = 'waitlisted'
      }
    }

    // 7. Insert registration
    const { data: reg, error: regError } = await serviceClient
      .from('event_registrations')
      .insert([{
        event_id: eventId,
        profile_id: user.id,
        status,
        waitlist_position: waitlistPosition,
      }])
      .select('id, event_id, status, waitlist_position, created_at')
      .single()

    if (regError) {
      return jsonResponse({ error: 'db_error', message: regError.message }, 500)
    }

    return jsonResponse({ success: true, registration: reg }, 200)
  } catch (err) {
    console.error('create-registration unexpected error', err)
    return jsonResponse({ error: 'internal', message: 'Internal server error' }, 500)
  }
})
