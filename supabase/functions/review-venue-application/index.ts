import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

type ReviewRole = 'general' | 'venue_approved'

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

function readJwtPayload(authHeader: string): Record<string, unknown> | null {
  try {
    const token = authHeader.replace(/^Bearer\s+/i, '')
    const encodedPayload = token.split('.')[1]
    if (!encodedPayload) return null
    const normalized = encodedPayload.replace(/-/g, '+').replace(/_/g, '/')
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=')
    const payload = JSON.parse(atob(padded))
    return payload && typeof payload === 'object' ? payload as Record<string, unknown> : null
  } catch {
    return null
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return jsonResponse({ error: 'method_not_allowed' }, 405)

  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return jsonResponse({ error: 'unauthorized' }, 401)

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  })
  const { data: { user: caller }, error: authError } = await callerClient.auth.getUser()
  if (authError || !caller) return jsonResponse({ error: 'unauthorized' }, 401)
  if (caller.app_metadata?.role !== 'admin' || readJwtPayload(authHeader)?.aal !== 'aal2') {
    return jsonResponse({ error: 'forbidden_admin_aal2_required' }, 403)
  }

  let body: Record<string, unknown>
  try {
    body = await req.json() as Record<string, unknown>
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400)
  }
  const targetUserId = body.target_user_id
  const newRole = body.new_role
  if (typeof targetUserId !== 'string' || !targetUserId) return jsonResponse({ error: 'target_user_id_required' }, 400)
  if (newRole !== 'general' && newRole !== 'venue_approved') return jsonResponse({ error: 'invalid_review_role' }, 400)

  const serviceClient = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } })
  const { data: profile, error: profileError } = await serviceClient
    .from('profiles')
    .select('role_status')
    .eq('id', targetUserId)
    .maybeSingle()
  if (profileError) return jsonResponse({ error: 'internal_error', message: profileError.message }, 500)
  if (!profile) return jsonResponse({ error: 'target_not_found' }, 404)
  if (profile.role_status !== 'venue_pending') return jsonResponse({ error: 'application_not_pending' }, 409)

  const { error: updateError } = await serviceClient
    .from('profiles')
    .update({ role_status: newRole as ReviewRole })
    .eq('id', targetUserId)
    .eq('role_status', 'venue_pending')
  if (updateError) return jsonResponse({ error: 'internal_error', message: updateError.message }, 500)

  const { error: auditError } = await serviceClient.from('audit_logs').insert({
    actor_id: caller.id,
    target_profile_id: targetUserId,
    action: 'role_upgrade',
    payload: { old_role: 'venue_pending', new_role: newRole, source: 'venue_application_review' },
  })
  if (auditError) return jsonResponse({ error: 'internal_error', message: auditError.message }, 500)

  return jsonResponse({ success: true, user_id: targetUserId, role_status: newRole }, 200)
})
