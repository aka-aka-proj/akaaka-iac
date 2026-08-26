import { createClient } from '@supabase/supabase-js'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const VALID_STATUSES = ['in_progress', 'resolved', 'closed'] as const

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

    const isAdmin = user.app_metadata?.role === 'admin'
    if (!isAdmin) {
      return jsonResponse({ error: 'forbidden', message: 'Admin access required' }, 403)
    }

    const body = (await req.json()) as { issue_id?: string; status?: string }
    const issueId = body.issue_id?.trim()
    const newStatus = body.status?.trim() as typeof VALID_STATUSES[number] | undefined

    if (!issueId) {
      return jsonResponse({ error: 'validation', message: 'issue_id is required' }, 400)
    }

    if (!newStatus || !(VALID_STATUSES as readonly string[]).includes(newStatus)) {
      return jsonResponse({ error: 'validation', message: `status must be one of: ${VALID_STATUSES.join(', ')}` }, 400)
    }

    const serviceClient = createClient(supabaseUrl, serviceRoleKey)

    // Verify issue exists and get current status
    const { data: issue, error: issueError } = await serviceClient
      .from('issues')
      .select('id, status')
      .eq('id', issueId)
      .maybeSingle()

    if (issueError) {
      return jsonResponse({ error: 'db_error', message: issueError.message }, 500)
    }

    if (!issue) {
      return jsonResponse({ error: 'not_found', message: 'Issue not found' }, 404)
    }

    // Prevent regression: cannot go back to 'open'
    if (issue.status === 'closed' || issue.status === 'resolved') {
      return jsonResponse({ error: 'invalid_transition', message: 'Cannot change status of a closed or resolved issue' }, 400)
    }

    // Update the issue status
    const { error: updateError } = await serviceClient
      .from('issues')
      .update({ status: newStatus, updated_at: new Date().toISOString() })
      .eq('id', issueId)

    if (updateError) {
      return jsonResponse({ error: 'db_error', message: updateError.message }, 500)
    }

    // Add a system comment recording the status change
    const commentContent = `Status changed to "${newStatus}" by admin`
    const { error: commentError } = await serviceClient
      .from('issue_comments')
      .insert({
        issue_id: issueId,
        profile_id: user.id,
        content: commentContent,
      })

    if (commentError) {
      console.error('update-issue-status: failed to add comment', commentError)
    }

    return jsonResponse({ success: true, issue_id: issueId, new_status: newStatus }, 200)
  } catch (err) {
    console.error('update-issue-status unexpected error', err)
    return jsonResponse({ error: 'internal', message: 'Internal server error' }, 500)
  }
})