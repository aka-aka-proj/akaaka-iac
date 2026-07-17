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

    const body = (await req.json()) as { issue_id?: string; content?: string }
    const issueId = body.issue_id?.trim()
    const content = body.content?.trim()

    if (!issueId || !content) {
      return jsonResponse({ error: 'validation', message: 'issue_id and content are required' }, 400)
    }

    const serviceClient = createClient(supabaseUrl, serviceRoleKey)

    // Verify issue exists
    const { data: issue, error: issueError } = await serviceClient
      .from('issues')
      .select('id, reporter_id')
      .eq('id', issueId)
      .maybeSingle()

    if (issueError) {
      return jsonResponse({ error: 'db_error', message: issueError.message }, 500)
    }

    if (!issue) {
      return jsonResponse({ error: 'not_found', message: 'Issue not found' }, 404)
    }

    // Check permission: reporter or admin
    const isAdmin = (user.app_metadata?.role as string | undefined) === 'admin'
    if (issue.reporter_id !== user.id && !isAdmin) {
      return jsonResponse({ error: 'forbidden', message: 'You can only comment on your own issues' }, 403)
    }

    const { data, error } = await serviceClient
      .from('issue_comments')
      .insert({
        issue_id: issueId,
        profile_id: user.id,
        content,
      })
      .select('id')
      .single()

    if (error) {
      return jsonResponse({ error: 'db_error', message: error.message }, 500)
    }

    return jsonResponse({ success: true, comment_id: data.id }, 200)
  } catch (err) {
    console.error('add-issue-comment unexpected error', err)
    return jsonResponse({ error: 'internal', message: 'Internal server error' }, 500)
  }
})
