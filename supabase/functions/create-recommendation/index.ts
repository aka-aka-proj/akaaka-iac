import { withSupabase } from 'npm:@supabase/server'

export default {
  fetch: withSupabase({ auth: 'user' }, async (req: Request, ctx) => {
    try {
      const body = (await req.json()) as { to_profile_id?: string; comment?: string }
      const toProfileId = body.to_profile_id
      const comment = body.comment

      if (!toProfileId) {
        return Response.json(
          { error: 'invalid', message: 'to_profile_id is required' },
          { status: 400 },
        )
      }

      if (ctx.user.id === toProfileId) {
        return Response.json(
          { error: 'invalid', message: 'You cannot recommend yourself.' },
          { status: 400 },
        )
      }

      // Rate-limit check: at most one recommendation per 24 h per (from, to) pair
      const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()
      const { count, error: countError } = await ctx.supabase
        .from('recommendations')
        .select('id', { count: 'exact', head: true })
        .eq('from_profile_id', ctx.user.id)
        .eq('to_profile_id', toProfileId)
        .gte('created_at', since)

      if (countError) {
        return Response.json({ error: 'db_error', message: countError.message }, { status: 500 })
      }

      if ((count ?? 0) >= 1) {
        return Response.json(
          {
            error: 'rate_limited',
            message: 'You can only recommend this person once every 24 hours',
          },
          { status: 429 },
        )
      }

      // Insert via admin client (bypasses RLS for the write path)
      const { data: insertData, error: insertError } = await ctx.supabaseAdmin
        .from('recommendations')
        .insert([
          {
            from_profile_id: ctx.user.id,
            to_profile_id: toProfileId,
            score_increment: 1,
            comment: comment?.trim() || null,
          },
        ])
        .select('id')
        .single()

      if (insertError) {
        if (insertError.message.includes('rate_limited')) {
          return Response.json(
            {
              error: 'rate_limited',
              message: 'You can only recommend this person once every 24 hours',
            },
            { status: 429 },
          )
        }
        return Response.json({ error: 'db_error', message: insertError.message }, { status: 500 })
      }

      return Response.json({ success: true, recommendation_id: insertData.id })
    } catch (err) {
      console.error('create-recommendation unexpected error', err)
      return Response.json(
        { error: 'internal', message: 'Internal server error' },
        { status: 500 },
      )
    }
  }),
}
