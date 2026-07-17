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
      const body = (await req.json()) as { issue_id?: string; content?: string }
      const issueId = body.issue_id?.trim()
      const content = body.content?.trim()

      if (!issueId || !content) {
        return Response.json(
          { error: 'validation', message: 'issue_id and content are required' },
          { status: 400 },
        )
      }

      // Verify issue exists
      const { data: issue, error: issueError } = await ctx.supabaseAdmin
        .from('issues')
        .select('id, reporter_id')
        .eq('id', issueId)
        .maybeSingle()

      if (issueError) {
        return Response.json({ error: 'db_error', message: issueError.message }, { status: 500 })
      }

      if (!issue) {
        return Response.json({ error: 'not_found', message: 'Issue not found' }, { status: 404 })
      }

      // Check permission: reporter or admin
      const isAdmin = (ctx.user.app_metadata?.role as string | undefined) === 'admin'
      if (issue.reporter_id !== ctx.user.id && !isAdmin) {
        return Response.json(
          { error: 'forbidden', message: 'You can only comment on your own issues' },
          { status: 403 },
        )
      }

      const { data, error } = await ctx.supabaseAdmin
        .from('issue_comments')
        .insert({
          issue_id: issueId,
          profile_id: ctx.user.id,
          content,
        })
        .select('id')
        .single()

      if (error) {
        return Response.json({ error: 'db_error', message: error.message }, { status: 500 })
      }

      return Response.json({ success: true, comment_id: data.id })
    } catch (err) {
      console.error('add-issue-comment unexpected error', err)
      return Response.json(
        { error: 'internal', message: 'Internal server error' },
        { status: 500 },
      )
    }
  }),
}
