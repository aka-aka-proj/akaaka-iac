import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

type RoleStatus = 'general' | 'venue_pending' | 'venue_approved'
const VALID_ROLES: RoleStatus[] = ['general', 'venue_pending', 'venue_approved']

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  const authHeader = req.headers.get('Authorization')
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Missing authorization header' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

  // Verify the caller's JWT via a user-scoped client
  const callerClient = createClient(supabaseUrl, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  })

  const { data: { user: callerUser }, error: authError } = await callerClient.auth.getUser()
  if (authError || !callerUser) {
    return new Response(JSON.stringify({ error: 'Invalid or expired token' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  // Enforce admin claim — must be present in app_metadata.role
  const callerRole = callerUser.app_metadata?.role as string | undefined
  if (callerRole !== 'admin') {
    return new Response(JSON.stringify({ error: 'Forbidden: admin role required' }), {
      status: 403,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  // Parse and validate request body
  let body: unknown
  try {
    body = await req.json()
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  const { target_user_id, new_role } = (body ?? {}) as Record<string, unknown>

  if (!target_user_id || typeof target_user_id !== 'string') {
    return new Response(JSON.stringify({ error: 'target_user_id is required and must be a string' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  if (!new_role || !VALID_ROLES.includes(new_role as RoleStatus)) {
    return new Response(
      JSON.stringify({ error: `new_role must be one of: ${VALID_ROLES.join(', ')}` }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  }

  // Use service-role client for privileged DB operations
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  })

  // Fetch current role so we can log old_role and confirm user exists
  const { data: existingProfile, error: fetchError } = await adminClient
    .from('profiles')
    .select('role_status')
    .eq('id', target_user_id)
    .maybeSingle()

  if (fetchError) {
    return new Response(JSON.stringify({ error: fetchError.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  if (!existingProfile) {
    return new Response(JSON.stringify({ error: 'Target user not found' }), {
      status: 404,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  const old_role = existingProfile.role_status as RoleStatus

  // Update role
  const { error: updateError } = await adminClient
    .from('profiles')
    .update({ role_status: new_role })
    .eq('id', target_user_id)

  if (updateError) {
    return new Response(JSON.stringify({ error: updateError.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  // Write audit log
  const { error: auditError } = await adminClient.from('audit_logs').insert({
    actor_id: callerUser.id,
    target_profile_id: target_user_id,
    action: 'role_upgrade',
    payload: { old_role, new_role },
  })

  if (auditError) {
    // Audit failure is treated as a server error — role change already applied
    return new Response(JSON.stringify({ error: `Audit log failed: ${auditError.message}` }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  return new Response(
    JSON.stringify({ success: true, user_id: target_user_id, new_role }),
    { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
  )
})
