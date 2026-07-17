import { withSupabase } from 'npm:@supabase/server'

const VALID_ACTIONS = ['warn', 'suspend', 'ban', 'role_upgrade', 'role_revoke', 'note'] as const
type ActionType = (typeof VALID_ACTIONS)[number]

export default {
  fetch: withSupabase({ auth: 'user' }, async (req: Request, ctx) => {
    if (req.method !== 'POST') {
      return Response.json({ error: 'Method not allowed' }, { status: 405 })
    }

    try {
      // Enforce admin role claim
      if ((ctx.user.app_metadata?.role as string | undefined) !== 'admin') {
        return Response.json({ error: 'Forbidden: admin role required' }, { status: 403 })
      }

      // Parse and validate request body
      let body: Record<string, unknown>
      try {
        body = await req.json()
      } catch {
        return Response.json({ error: 'Invalid JSON body' }, { status: 400 })
      }

      const { action_type, target_profile_id, report_id, payload } = body as {
        action_type: unknown
        target_profile_id: unknown
        report_id?: unknown
        payload: unknown
      }

      if (!action_type || !VALID_ACTIONS.includes(action_type as ActionType)) {
        return Response.json(
          { error: `Invalid or missing action_type. Must be one of: ${VALID_ACTIONS.join(', ')}` },
          { status: 400 },
        )
      }
      if (!target_profile_id || typeof target_profile_id !== 'string') {
        return Response.json({ error: 'Missing or invalid target_profile_id' }, { status: 400 })
      }
      if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
        return Response.json(
          { error: 'Missing or invalid payload (must be an object)' },
          { status: 400 },
        )
      }

      const typedAction = action_type as ActionType
      const typedPayload = payload as Record<string, unknown>

      // role_upgrade requires new_role in payload
      if (typedAction === 'role_upgrade' && !typedPayload.new_role) {
        return Response.json(
          { error: 'Missing payload.new_role for role_upgrade action' },
          { status: 400 },
        )
      }

      // Verify target profile exists
      const { data: targetProfile, error: profileFetchError } = await ctx.supabaseAdmin
        .from('profiles')
        .select('id, metadata')
        .eq('id', target_profile_id)
        .maybeSingle()

      if (profileFetchError) {
        return Response.json({ error: profileFetchError.message }, { status: 500 })
      }
      if (!targetProfile) {
        return Response.json({ error: 'Target profile not found' }, { status: 404 })
      }

      // 1. INSERT into moderation_actions
      const { data: moderationAction, error: insertError } = await ctx.supabaseAdmin
        .from('moderation_actions')
        .insert({
          admin_id: ctx.user.id,
          action_type: typedAction,
          target_profile_id,
          report_id: report_id ?? null,
          payload: typedPayload,
        })
        .select('id')
        .single()

      if (insertError) {
        return Response.json({ error: insertError.message }, { status: 500 })
      }

      // 2. Action-specific profile updates
      if (typedAction === 'role_upgrade') {
        const { error } = await ctx.supabaseAdmin
          .from('profiles')
          .update({ role_status: typedPayload.new_role as string })
          .eq('id', target_profile_id)
        if (error) return Response.json({ error: error.message }, { status: 500 })
      } else if (typedAction === 'role_revoke') {
        const { error } = await ctx.supabaseAdmin
          .from('profiles')
          .update({ role_status: 'general' })
          .eq('id', target_profile_id)
        if (error) return Response.json({ error: error.message }, { status: 500 })
      } else if (typedAction === 'suspend' || typedAction === 'ban') {
        const currentMetadata = (targetProfile.metadata as Record<string, unknown>) ?? {}
        const { error } = await ctx.supabaseAdmin
          .from('profiles')
          .update({
            metadata: {
              ...currentMetadata,
              moderation_status: typedAction,
              moderated_at: new Date().toISOString(),
            },
          })
          .eq('id', target_profile_id)
        if (error) return Response.json({ error: error.message }, { status: 500 })
      }

      // 3. INSERT into audit_logs
      const { error: auditError } = await ctx.supabaseAdmin.from('audit_logs').insert({
        actor_id: ctx.user.id,
        target_profile_id,
        action: typedAction,
        payload: typedPayload,
      })
      if (auditError) {
        return Response.json({ error: auditError.message }, { status: 500 })
      }

      // 4. Update report status if report_id provided
      if (report_id && typeof report_id === 'string') {
        const definitiveActions: ActionType[] = ['ban', 'role_revoke']
        const newStatus = definitiveActions.includes(typedAction) ? 'resolved' : 'triaging'
        const { error: reportError } = await ctx.supabaseAdmin
          .from('reports')
          .update({ status: newStatus })
          .eq('id', report_id)
        if (reportError) {
          return Response.json({ error: reportError.message }, { status: 500 })
        }
      }

      return Response.json({ success: true, moderation_action_id: moderationAction.id })
    } catch (err) {
      return Response.json(
        { error: err instanceof Error ? err.message : 'Internal server error' },
        { status: 500 },
      )
    }
  }),
}
