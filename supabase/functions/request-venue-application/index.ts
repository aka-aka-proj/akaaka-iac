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
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return jsonResponse({ error: 'method_not_allowed' }, 405)

  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return jsonResponse({ error: 'unauthorized' }, 401)

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  })
  const { data: { user }, error: authError } = await userClient.auth.getUser()
  if (authError || !user) return jsonResponse({ error: 'unauthorized' }, 401)

  const serviceClient = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } })
  const { data: profile, error: profileError } = await serviceClient
    .from('profiles')
    .select('role_status')
    .eq('id', user.id)
    .maybeSingle()
  if (profileError) return jsonResponse({ error: 'internal_error', message: profileError.message }, 500)
  if (!profile) return jsonResponse({ error: 'not_found' }, 404)

  if (profile.role_status === 'venue_pending') {
    return jsonResponse({ error: 'conflict', message: 'Venue application is already pending' }, 409)
  }
  if (profile.role_status !== 'general') {
    return jsonResponse({ error: 'business_rule_violation', message: 'Venue application is unavailable for this role' }, 422)
  }

  const { error: updateError } = await serviceClient
    .from('profiles')
    .update({ role_status: 'venue_pending' })
    .eq('id', user.id)
    .eq('role_status', 'general')
  if (updateError) return jsonResponse({ error: 'internal_error', message: updateError.message }, 500)

  const { error: auditError } = await serviceClient.from('audit_logs').insert({
    actor_id: user.id,
    target_profile_id: user.id,
    action: 'role_status_change',
    payload: { old_status: 'general', new_status: 'venue_pending', source: 'venue_application' },
  })
  if (auditError) return jsonResponse({ error: 'internal_error', message: auditError.message }, 500)

  return jsonResponse({ success: true, role_status: 'venue_pending' }, 200)
})
