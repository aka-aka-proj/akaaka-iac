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

  if (req.method !== 'POST') {
    return jsonResponse({ error: 'method_not_allowed', message: 'Only POST is allowed' }, 405)
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return jsonResponse({ error: 'unauthorized', message: 'Missing authorization header' }, 401)
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

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

    const userId = user.id

    const serviceClient = createClient(supabaseUrl, serviceRoleKey)

    // Delete related data that references profiles (no ON DELETE CASCADE)
    await serviceClient.from('events').delete().eq('creator_id', userId)
    await serviceClient.from('event_threads').delete().eq('profile_id', userId)
    await serviceClient.from('recommendations').delete().eq('from_profile_id', userId)
    await serviceClient.from('recommendations').delete().eq('to_profile_id', userId)
    await serviceClient.from('blocks').delete().eq('blocker_id', userId)
    await serviceClient.from('blocks').delete().eq('blocked_id', userId)
    await serviceClient.from('reports').delete().eq('reporter_id', userId)
    await serviceClient.from('moderation_actions').delete().eq('admin_id', userId)
    await serviceClient.from('moderation_actions').delete().eq('target_profile_id', userId)
    await serviceClient.from('audit_logs').delete().eq('actor_id', userId)
    await serviceClient.from('audit_logs').delete().eq('target_profile_id', userId)

    // Delete profile
    const { error: deleteProfileError } = await serviceClient
      .from('profiles')
      .delete()
      .eq('id', userId)

    if (deleteProfileError) {
      return jsonResponse({ error: 'db_error', message: deleteProfileError.message }, 500)
    }

    const { error: deleteUserError } = await serviceClient.auth.admin.deleteUser(userId)

    if (deleteUserError) {
      return jsonResponse({ error: 'auth_error', message: deleteUserError.message }, 500)
    }

    return jsonResponse({ success: true }, 200)
  } catch (err) {
    console.error('delete-account unexpected error', err)
    return jsonResponse({ error: 'internal', message: 'Internal server error' }, 500)
  }
})
