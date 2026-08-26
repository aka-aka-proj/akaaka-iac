import { createClient } from '@supabase/supabase-js'

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

  if (req.method !== 'GET') {
    return jsonResponse({ error: 'method_not_allowed', message: 'Only GET is allowed' }, 405)
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

    const isAdmin = user.app_metadata?.role === 'admin'
    if (!isAdmin) {
      return jsonResponse({ error: 'forbidden', message: 'Admin access required' }, 403)
    }

    const serviceClient = createClient(supabaseUrl, serviceRoleKey)

    const { data: issues, error } = await serviceClient
      .from('issues')
      .select('id, title, status, created_at, updated_at, reporter_id')
      .order('created_at', { ascending: false })

    if (error) {
      return jsonResponse({ error: 'db_error', message: error.message }, 500)
    }

    return jsonResponse({ issues: issues ?? [] }, 200)
  } catch (err) {
    console.error('list-all-issues unexpected error', err)
    return jsonResponse({ error: 'internal', message: 'Internal server error' }, 500)
  }
})