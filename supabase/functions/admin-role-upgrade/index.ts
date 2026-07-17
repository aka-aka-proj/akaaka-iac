import { withSupabase } from 'npm:@supabase/server'

type RoleStatus = 'general' | 'venue_pending' | 'venue_approved'
const VALID_ROLES: RoleStatus[] = ['general', 'venue_pending', 'venue_approved']

export default {
  fetch: withSupabase({ auth: 'user' }, async (req: Request, ctx) => {
    // Enforce admin claim
    if ((ctx.user.app_metadata?.role as string | undefined) !== 'admin') {
      return Response.json({ error: 'Forbidden: admin role required' }, { status: 403 })
    }

    // Parse and validate request body
    let body: unknown
    try {
      body = await req.json()
    } catch {
      return Response.json({ error: 'Invalid JSON body' }, { status: 400 })
    }

    const { target_user_id, new_role } = (body ?? {}) as Record<string, unknown>

    if (!target_user_id || typeof target_user_id !== 'string') {
      return Response.json(
        { error: 'target_user_id is required and must be a string' },
        { status: 400 },
      )
    }

    if (!new_role || !VALID_ROLES.includes(new_role as RoleStatus)) {
      return Response.json(
        { error: `new_role must be one of: ${VALID_ROLES.join(', ')}` },
        { status: 400 },
      )
    }

    // Fetch current role so we can log old_role and confirm user exists
    const { data: existingProfile, error: fetchError } = await ctx.supabaseAdmin
      .from('profiles')
      .select('role_status')
      .eq('id', target_user_id)
      .maybeSingle()

    if (fetchError) {
      return Response.json({ error: fetchError.message }, { status: 500 })
    }

    if (!existingProfile) {
      return Response.json({ error: 'Target user not found' }, { status: 404 })
    }

    const old_role = existingProfile.role_status as RoleStatus

    // Update role
    const { error: updateError } = await ctx.supabaseAdmin
      .from('profiles')
      .update({ role_status: new_role })
      .eq('id', target_user_id)

    if (updateError) {
      return Response.json({ error: updateError.message }, { status: 500 })
    }

    // Write audit log
    const { error: auditError } = await ctx.supabaseAdmin.from('audit_logs').insert({
      actor_id: ctx.user.id,
      target_profile_id: target_user_id,
      action: 'role_upgrade',
      payload: { old_role, new_role },
    })

    if (auditError) {
      return Response.json(
        { error: `Audit log failed: ${auditError.message}` },
        { status: 500 },
      )
    }

    return Response.json({ success: true, user_id: target_user_id, new_role })
  }),
}
