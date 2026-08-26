import { createClient } from '@supabase/supabase-js'

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const VALID_ACTIONS = ['warn', 'suspend', 'ban', 'role_upgrade', 'role_revoke', 'note'] as const
type ActionType = (typeof VALID_ACTIONS)[number]
const VALID_REPORT_STATUSES = ['triaging', 'resolved', 'rejected'] as const
const VALID_REJECTION_REASONS = [
  'insufficient_evidence',
  'duplicate',
  'out_of_scope',
  'no_policy_violation',
  'other',
] as const

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

    const callerRole = user.app_metadata?.role as string | undefined
    if (callerRole !== 'admin') {
      return jsonResponse({ error: 'Forbidden: admin role required' }, 403)
    }

    // Parse and validate request body
    let body: Record<string, unknown>
    try {
      body = await req.json()
    } catch {
      return jsonResponse({ error: 'Invalid JSON body' }, 400)
    }

    const {
      action_type,
      target_profile_id,
      report_id,
      payload,
      report_status,
      rejection_reason_code,
    } = body as {
      action_type: unknown
      target_profile_id: unknown
      report_id?: unknown
      payload: unknown
      report_status?: unknown
      rejection_reason_code?: unknown
    }

    if (!action_type || !VALID_ACTIONS.includes(action_type as ActionType)) {
      return jsonResponse({ error: `Invalid or missing action_type. Must be one of: ${VALID_ACTIONS.join(', ')}` }, 400)
    }
    if (target_profile_id !== undefined && target_profile_id !== null && typeof target_profile_id !== 'string') {
      return jsonResponse({ error: 'Invalid target_profile_id' }, 400)
    }
    if (report_id !== undefined && report_id !== null && typeof report_id !== 'string') {
      return jsonResponse({ error: 'Invalid report_id' }, 400)
    }
    if (!target_profile_id && !report_id) {
      return jsonResponse({ error: 'target_profile_id or report_id is required' }, 400)
    }
    if (['suspend', 'ban', 'role_upgrade', 'role_revoke'].includes(action_type as string) && !target_profile_id) {
      return jsonResponse({ error: `target_profile_id is required for ${action_type}` }, 400)
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

    const requestedReportStatus = report_status === undefined
      ? undefined
      : String(report_status)
    if (requestedReportStatus && !VALID_REPORT_STATUSES.includes(requestedReportStatus as typeof VALID_REPORT_STATUSES[number])) {
      return jsonResponse({ error: `Invalid report_status. Must be one of: ${VALID_REPORT_STATUSES.join(', ')}` }, 400)
    }
    const requestedRejectionReason = rejection_reason_code === undefined
      ? undefined
      : String(rejection_reason_code)
    if (requestedReportStatus === 'rejected' && !VALID_REJECTION_REASONS.includes(requestedRejectionReason as typeof VALID_REJECTION_REASONS[number])) {
      return jsonResponse({ error: 'rejection_reason_code is required and invalid for rejected reports' }, 400)
    }
    if (requestedReportStatus !== 'rejected' && requestedRejectionReason !== undefined) {
      return jsonResponse({ error: 'rejection_reason_code is only valid for rejected reports' }, 400)
    }

    const serviceClient = createClient(supabaseUrl, serviceKey)

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
      const { error } = await serviceClient.rpc('set_profile_moderation_status', {
        target_id: target_profile_id,
        moderation_status: typedAction,
      })
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
      const newStatus = requestedReportStatus ?? (definitiveActions.includes(typedAction) ? 'resolved' : 'triaging')
      const { error: reportError } = await serviceClient
        .from('reports')
        .update({
          status: newStatus,
          rejection_reason_code: newStatus === 'rejected' ? requestedRejectionReason : null,
        })
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
