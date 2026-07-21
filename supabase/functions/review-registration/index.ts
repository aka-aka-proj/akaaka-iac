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

    const body = (await req.json()) as { event_id?: string; registration_id?: string; action?: string }
    const eventId = body.event_id
    const registrationId = body.registration_id
    const action = body.action

    if (!eventId || !registrationId || !action) {
      return jsonResponse({ error: 'invalid', message: 'event_id, registration_id, and action are required' }, 400)
    }

    if (action !== 'approve' && action !== 'reject') {
      return jsonResponse({ error: 'invalid', message: 'action must be "approve" or "reject"' }, 400)
    }

    const serviceClient = createClient(supabaseUrl, serviceRoleKey)

    // Verify caller is the event host
    const { data: event, error: eventError } = await serviceClient
      .from('events')
      .select('id, creator_id, max_capacity')
      .eq('id', eventId)
      .single()

    if (eventError || !event) {
      return jsonResponse({ error: 'not_found', message: 'Event not found' }, 404)
    }

    if (event.creator_id !== user.id) {
      return jsonResponse({ error: 'forbidden', message: 'Only the event host can review registrations' }, 403)
    }

    // Fetch the registration
    const { data: reg, error: regError } = await serviceClient
      .from('event_registrations')
      .select('id, status')
      .eq('id', registrationId)
      .eq('event_id', eventId)
      .single()

    if (regError || !reg) {
      return jsonResponse({ error: 'not_found', message: 'Registration not found' }, 404)
    }

    if (reg.status !== 'pending' && reg.status !== 'cancellation_pending') {
      return jsonResponse({ error: 'invalid_status_transition', message: `Cannot ${action} a registration in '${reg.status}' status` }, 400)
    }

    // Capacity check for approve new registrations (ignore for cancellation approvals)
    if (action === 'approve' && reg.status === 'pending' && event.max_capacity) {
      const { count: approvedCount } = await serviceClient
        .from('event_registrations')
        .select('id', { count: 'exact', head: true })
        .eq('event_id', eventId)
        .eq('status', 'approved')

      if ((approvedCount ?? 0) >= event.max_capacity) {
        return jsonResponse({ error: 'capacity_reached', message: 'Cannot approve more registrations, capacity reached' }, 400)
      }
    }

    let newStatus: string
    if (reg.status === 'cancellation_pending') {
      // Approving cancellation -> cancelled, Rejecting cancellation -> cancellation_rejected
      newStatus = action === 'approve' ? 'cancelled' : 'cancellation_rejected'
    } else {
      // Approving registration -> approved, Rejecting registration -> rejected
      newStatus = action === 'approve' ? 'approved' : 'rejected'
    }

    const { data: updated, error: updateError } = await serviceClient
      .from('event_registrations')
      .update({
        status: newStatus,
        reviewed_by: user.id,
        reviewed_at: new Date().toISOString(),
      })
      .eq('id', registrationId)
      .select('id, status, reviewed_by, reviewed_at')
      .single()

    if (updateError) {
      return jsonResponse({ error: 'db_error', message: updateError.message }, 500)
    }

    return jsonResponse({ success: true, registration: updated }, 200)
  } catch (err) {
    console.error('review-registration unexpected error', err)
    return jsonResponse({ error: 'internal', message: 'Internal server error' }, 500)
  }
})
