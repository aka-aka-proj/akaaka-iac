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

    // Find the active registration for this user on this event
    const { data: reg, error: regError } = await serviceClient
      .from('event_registrations')
      .select('id, status')
      .eq('event_id', eventId)
      .eq('profile_id', user.id)
      .neq('status', 'cancelled')
      .maybeSingle()

    if (regError) {
      return jsonResponse({ error: 'db_error', message: regError.message }, 500)
    }

    if (!reg) {
      return jsonResponse({ error: 'not_found', message: 'No active registration found' }, 404)
    }

    // Cannot cancel a rejected registration
    if (reg.status === 'rejected') {
      return jsonResponse({ error: 'invalid_status', message: 'Cannot cancel a rejected registration' }, 400)
    }

    // Set status to cancelled — the DB trigger will handle waitlist promotion
    const { error: updateError } = await serviceClient
      .from('event_registrations')
      .update({ status: 'cancelled' })
      .eq('id', reg.id)

    if (updateError) {
      return jsonResponse({ error: 'db_error', message: updateError.message }, 500)
    }

    return jsonResponse({ success: true, message: 'Registration cancelled' }, 200)
  } catch (err) {
    console.error('cancel-registration unexpected error', err)
    return jsonResponse({ error: 'internal', message: 'Internal server error' }, 500)
  }
})
