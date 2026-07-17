import { withSupabase } from 'npm:@supabase/server'

export default {
  fetch: withSupabase({ auth: 'user' }, async (_req: Request, ctx) => {
    try {
      const { data: issues, error } = await ctx.supabaseAdmin
        .from('issues')
        .select('id, title, status, created_at, log_url')
        .eq('reporter_id', ctx.user.id)
        .order('created_at', { ascending: false })

      if (error) {
        return Response.json({ error: 'db_error', message: error.message }, { status: 500 })
      }

      return Response.json({ issues: issues ?? [] })
    } catch (err) {
      console.error('list-my-issues unexpected error', err)
      return Response.json(
        { error: 'internal', message: 'Internal server error' },
        { status: 500 },
      )
    }
  }),
}
