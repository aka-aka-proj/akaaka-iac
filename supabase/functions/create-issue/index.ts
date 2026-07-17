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

    const body = (await req.json()) as { title?: string; description?: string; log_url?: string }
    const title = body.title?.trim()
    const description = body.description?.trim()
    const logUrl = body.log_url?.trim() || null

    if (!title || !description) {
      return jsonResponse({ error: 'validation', message: 'title and description are required' }, 400)
    }

    const serviceClient = createClient(supabaseUrl, serviceRoleKey)

    const { data, error } = await serviceClient
      .from('issues')
      .insert({
        reporter_id: user.id,
        title,
        description,
        log_url: logUrl,
      })
      .select('id')
      .single()

    if (error) {
      return jsonResponse({ error: 'db_error', message: error.message }, 500)
    }

    return jsonResponse({ success: true, issue_id: data.id }, 200)
  } catch (err) {
    console.error('create-issue unexpected error', err)
    return jsonResponse({ error: 'internal', message: 'Internal server error' }, 500)
  }
})
