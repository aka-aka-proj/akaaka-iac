import { withSupabase } from 'npm:@supabase/server'

export default {
  fetch: withSupabase({ auth: 'user' }, async (req: Request, ctx) => {
    if (req.method !== 'POST') {
      return Response.json(
        { error: 'method_not_allowed', message: 'Only POST is allowed' },
        { status: 405 },
      )
    }

    try {
      const body = (await req.json()) as { title?: string; description?: string; log_url?: string }
      const title = body.title?.trim()
      const description = body.description?.trim()
      const logUrl = body.log_url?.trim() || null

      if (!title || !description) {
        return Response.json(
          { error: 'validation', message: 'title and description are required' },
          { status: 400 },
        )
      }

      const { data, error } = await ctx.supabaseAdmin
        .from('issues')
        .insert({
          reporter_id: ctx.user.id,
          title,
          description,
          log_url: logUrl,
        })
        .select('id')
        .single()

      if (error) {
        return Response.json({ error: 'db_error', message: error.message }, { status: 500 })
      }

      return Response.json({ success: true, issue_id: data.id })
    } catch (err) {
      console.error('create-issue unexpected error', err)
      return Response.json(
        { error: 'internal', message: 'Internal server error' },
        { status: 500 },
      )
    }
  }),
}
