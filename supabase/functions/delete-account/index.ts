import { withSupabase } from 'npm:@supabase/server'

export default {
  fetch: withSupabase({ auth: 'user' }, async (_req: Request, ctx) => {
    try {
      const userId = ctx.user.id

      // Delete related data that references profiles (no ON DELETE CASCADE)
      await ctx.supabaseAdmin.from('events').delete().eq('creator_id', userId)
      await ctx.supabaseAdmin.from('event_threads').delete().eq('profile_id', userId)
      await ctx.supabaseAdmin.from('recommendations').delete().eq('from_profile_id', userId)
      await ctx.supabaseAdmin.from('recommendations').delete().eq('to_profile_id', userId)
      await ctx.supabaseAdmin.from('blocks').delete().eq('blocker_id', userId)
      await ctx.supabaseAdmin.from('blocks').delete().eq('blocked_id', userId)
      await ctx.supabaseAdmin.from('reports').delete().eq('reporter_id', userId)
      await ctx.supabaseAdmin.from('moderation_actions').delete().eq('admin_id', userId)
      await ctx.supabaseAdmin.from('moderation_actions').delete().eq('target_profile_id', userId)
      await ctx.supabaseAdmin.from('audit_logs').delete().eq('actor_id', userId)
      await ctx.supabaseAdmin.from('audit_logs').delete().eq('target_profile_id', userId)

      // Delete profile
      const { error: deleteProfileError } = await ctx.supabaseAdmin
        .from('profiles')
        .delete()
        .eq('id', userId)

      if (deleteProfileError) {
        return Response.json(
          { error: 'db_error', message: deleteProfileError.message },
          { status: 500 },
        )
      }

      const { error: deleteUserError } = await ctx.supabaseAdmin.auth.admin.deleteUser(userId)

      if (deleteUserError) {
        return Response.json(
          { error: 'auth_error', message: deleteUserError.message },
          { status: 500 },
        )
      }

      return Response.json({ success: true })
    } catch (err) {
      console.error('delete-account unexpected error', err)
      return Response.json(
        { error: 'internal', message: 'Internal server error' },
        { status: 500 },
      )
    }
  }),
}
