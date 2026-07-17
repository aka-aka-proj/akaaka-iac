import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const VALID_ACTIONS = ['warn', 'suspend', 'ban', 'role_upgrade', 'role_revoke', 'note'] as const
type ActionType = (typeof VALID_ACTIONS)[number]

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS })
  }

  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405)
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return jsonResponse({ error: 'No authorization header' }, 401)
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!

    // Verify the caller's JWT and extract user identity
    const anonClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    })
    const {
      data: { user },
      error: authError,
    } = await anonClient.auth.getUser()

    if (authError || !user) {
      return jsonResponse({ error: 'Unauthorized' }, 401)
    }

    // Enforce admin role claim
    if ((user.app_metadata?.role as string | undefined) !== 'admin') {
      return jsonResponse({ error: 'Forbidden: admin role required' }, 403)
    }

    // Parse and validate request body
    let body: Record<string, unknown>
    try {
      body = await req.json()
    } catch {
      return jsonResponse({ error: 'Invalid JSON body' }, 400)
    }

    const { action_type, target_profile_id, report_id, payload } = body as {
      action_type: unknown
      target_profile_id: unknown
      report_id?: unknown
      payload: unknown
    }

    if (!action_type || !VALID_ACTIONS.includes(action_type as ActionType)) {
      return jsonResponse({ error: `Invalid or missing action_type. Must be one of: ${VALID_ACTIONS.join(', ')}` }, 400)
    }
    if (!target_profile_id || typeof target_profile_id !== 'string') {
      return jsonResponse({ error: 'Missing or invalid target_profile_id' }, 400)
    }
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      return jsonResponse({ error: 'Missing or invalid payload (must be an object)' }, 400)
    }

    const typedAction = action_type as ActionType
    const typedPayload = payload as Record<string, unknown>

    // role_upgrade requires new_role in payload
    if (typedAction === 'role_upgrade' && !typedPayload.new_role) {
      return jsonResponse({ error: 'Missing payload.new_role for role_upgrade action' }, 400)
    }

    const serviceClient = createClient(supabaseUrl, serviceKey)

    // Verify target profile exists
    const { data: targetProfile, error: profileFetchError } = await serviceClient
      .from('profiles')
      .select('id, metadata')
      .eq('id', target_profile_id)
      .maybeSingle()

    if (profileFetchError) {
      return jsonResponse({ error: profileFetchError.message }, 500)
    }
    if (!targetProfile) {
      return jsonResponse({ error: 'Target profile not found' }, 404)
    }

    // 1. INSERT into moderation_actions
    const { data: moderationAction, error: insertError } = await serviceClient
      .from('moderation_actions')
      .insert({
        admin_id: user.id,
        action_type: typedAction,
        target_profile_id,
        report_id: report_id ?? null,
        payload: typedPayload,
      })
      .select('id')
      .single()

    if (insertError) {
      return jsonResponse({ error: insertError.message }, 500)
    }

    // 2. Action-specific profile updates
    if (typedAction === 'role_upgrade') {
      const { error } = await serviceClient
        .from('profiles')
        .update({ role_status: typedPayload.new_role as string })
        .eq('id', target_profile_id)
      if (error) return jsonResponse({ error: error.message }, 500)
    } else if (typedAction === 'role_revoke') {
      const { error } = await serviceClient
        .from('profiles')
        .update({ role_status: 'general' })
        .eq('id', target_profile_id)
      if (error) return jsonResponse({ error: error.message }, 500)
    } else if (typedAction === 'suspend' || typedAction === 'ban') {
      const currentMetadata = (targetProfile.metadata as Record<string, unknown>) ?? {}
      const { error } = await serviceClient
        .from('profiles')
        .update({
          metadata: {
            ...currentMetadata,
            moderation_status: typedAction,
            moderated_at: new Date().toISOString(),
          },
        })
        .eq('id', target_profile_id)
      if (error) return jsonResponse({ error: error.message }, 500)
    }

    // 3. INSERT into audit_logs
    const { error: auditError } = await serviceClient.from('audit_logs').insert({
      actor_id: user.id,
      target_profile_id,
      action: typedAction,
      payload: typedPayload,
    })
    if (auditError) {
      return jsonResponse({ error: auditError.message }, 500)
    }

    // 4. Update report status if report_id provided
    if (report_id && typeof report_id === 'string') {
      const definitiveActions: ActionType[] = ['ban', 'role_revoke']
      const newStatus = definitiveActions.includes(typedAction) ? 'resolved' : 'triaging'
      const { error: reportError } = await serviceClient
        .from('reports')
        .update({ status: newStatus })
        .eq('id', report_id)
      if (reportError) {
        return jsonResponse({ error: reportError.message }, 500)
      }
    }

    return jsonResponse({ success: true, moderation_action_id: moderationAction.id }, 200)
  } catch (err) {
    return jsonResponse(
      { error: err instanceof Error ? err.message : 'Internal server error' },
      500,
    )
  }
})
