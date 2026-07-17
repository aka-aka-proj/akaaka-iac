import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return jsonResponse({ error: 'unauthorized', message: 'Missing authorization header' }, 401)
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    // User-scoped client — respects RLS for the rate-limit count query
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    })

    const {
      data: { user },
      error: authError,
    } = await userClient.auth.getUser()

    if (authError || !user) {
      return jsonResponse({ error: 'unauthorized', message: 'Invalid or expired token' }, 401)
    }

    const fromProfileId = user.id

    const body = (await req.json()) as { to_profile_id?: string; comment?: string }
    const toProfileId = body.to_profile_id
    const comment = body.comment

    if (!toProfileId) {
      return jsonResponse({ error: 'invalid', message: 'to_profile_id is required' }, 400)
    }

    if (fromProfileId === toProfileId) {
      return jsonResponse({ error: 'invalid', message: 'You cannot recommend yourself.' }, 400)
    }

    // Rate-limit check: at most one recommendation per 24 h per (from, to) pair
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()
    const { count, error: countError } = await userClient
      .from('recommendations')
      .select('id', { count: 'exact', head: true })
      .eq('from_profile_id', fromProfileId)
      .eq('to_profile_id', toProfileId)
      .gte('created_at', since)

    if (countError) {
      return jsonResponse({ error: 'db_error', message: countError.message }, 500)
    }

    if ((count ?? 0) >= 1) {
      return jsonResponse(
        {
          error: 'rate_limited',
          message: 'You can only recommend this person once every 24 hours',
        },
        429,
      )
    }

    // Insert via service-role client (bypasses RLS for the write path)
    const serviceClient = createClient(supabaseUrl, serviceRoleKey)
    const { data: insertData, error: insertError } = await serviceClient
      .from('recommendations')
      .insert([
        {
          from_profile_id: fromProfileId,
          to_profile_id: toProfileId,
          score_increment: 1,
          comment: comment?.trim() || null,
        },
      ])
      .select('id')
      .single()

    if (insertError) {
      // DB trigger can also raise rate_limited exception as belt-and-suspenders
      if (insertError.message.includes('rate_limited')) {
        return jsonResponse(
          {
            error: 'rate_limited',
            message: 'You can only recommend this person once every 24 hours',
          },
          429,
        )
      }
      return jsonResponse({ error: 'db_error', message: insertError.message }, 500)
    }

    return jsonResponse({ success: true, recommendation_id: insertData.id }, 200)
  } catch (err) {
    console.error('create-recommendation unexpected error', err)
    return jsonResponse({ error: 'internal', message: 'Internal server error' }, 500)
  }
})
