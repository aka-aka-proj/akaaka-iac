import { createClient } from '@supabase/supabase-js'
import { parseBlocklistAcknowledgment, blocklistConflictResponse } from '../_shared/blocklist-conflict.ts'

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

    const body = (await req.json()) as { event_id?: string; registration_id?: string; action?: string; acknowledge_blocklist_conflict?: unknown }
    const acknowledge = parseBlocklistAcknowledgment(body.acknowledge_blocklist_conflict)
    if (acknowledge === null) return jsonResponse({ error: 'invalid', message: 'acknowledge_blocklist_conflict must be boolean' }, 400)
    const eventId = body.event_id
    const registrationId = body.registration_id
    const action = body.action

    if (!eventId || !registrationId || !action) {
      return jsonResponse({ error: 'invalid', message: 'event_id, registration_id, and action are required' }, 400)
    }

    if (action !== 'approve' && action !== 'reject' && action !== 'reopen') {
      return jsonResponse({ error: 'invalid', message: 'action must be "approve", "reject", or "reopen"' }, 400)
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

    // State, capacity, conflict check and write share one event-row lock.
    const { data: updated, error: updateError } = await serviceClient
      .rpc('review_event_registration_checked', {
        p_event_id: eventId,
        p_registration_id: registrationId,
        p_host_id: user.id,
        p_action: action,
        p_acknowledge_blocklist_conflict: acknowledge,
      }).single()
    if (updateError) {
      const conflict = blocklistConflictResponse(updateError)
      if (conflict) return jsonResponse(conflict, 409)
      const code = updateError.message
      if (['not_found', 'forbidden', 'registration_blocked', 'capacity_reached', 'invalid_status_transition'].includes(code)) {
        return jsonResponse({ error: code, message: 'This registration cannot be updated.' }, code === 'not_found' ? 404 : code === 'forbidden' || code === 'registration_blocked' ? 403 : 400)
      }
      return jsonResponse({ error: 'db_error', message: 'Unable to update registration' }, 500)
    }

    return jsonResponse({ success: true, registration: updated }, 200)
  } catch (err) {
    console.error('review-registration unexpected error', err)
    return jsonResponse({ error: 'internal', message: 'Internal server error' }, 500)
  }
})
