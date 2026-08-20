import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

/**
 * Sentinel profile ID for anonymous (unauthenticated) client error captures.
 *
 * The following one row must exist in `profiles` on each Supabase project
 * (staging & production) for the FK constraint to accept anonymous inserts:
 *
 *   INSERT INTO profiles (id, role_status, display_name)
 *   VALUES ('00000000-0000-0000-0000-000000000001', 'general', 'System Error Reporter')
 *   ON CONFLICT (id) DO NOTHING;
 */
const ANONYMOUS_REPORTER_ID = '00000000-0000-0000-0000-000000000001'

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
    const body = (await req.json()) as {
      message?: string
      source?: string
      lineno?: number
      colno?: number
      stack?: string
      url?: string
      userAgent?: string
    }

    if (!body.message?.trim()) {
      return jsonResponse({ error: 'validation', message: 'message is required' }, 400)
    }

    const message = body.message.trim().slice(0, 500)
    const source = body.source?.trim().slice(0, 500) || ''
    const lineno = body.lineno ?? 0
    const colno = body.colno ?? 0
    const url = body.url?.trim().slice(0, 1000) || ''
    const userAgent = body.userAgent?.trim().slice(0, 500) || ''
    const stack = body.stack?.trim().slice(0, 5000) || ''

    const description = [
      `URL: ${url}`,
      `User Agent: ${userAgent}`,
      source ? `Source: ${source}:${lineno}:${colno}` : null,
      stack ? `Stack:\n${stack}` : null,
      `Captured: ${new Date().toISOString()}`,
    ]
      .filter(Boolean)
      .join('\n')

    const title = source
      ? `Auto-captured client error: ${message} (${source}:${lineno})`
      : `Auto-captured client error: ${message}`

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    const serviceClient = createClient(supabaseUrl, serviceRoleKey)

    const { data, error } = await serviceClient
      .from('issues')
      .insert({
        reporter_id: ANONYMOUS_REPORTER_ID,
        title: title.slice(0, 255),
        description: description.slice(0, 5000),
        log_url: url || null,
      })
      .select('id')
      .single()

    if (error) {
      console.error('capture-error db insert failed', error)
      return jsonResponse({ error: 'db_error', message: error.message }, 500)
    }

    return jsonResponse({ success: true, issue_id: data.id }, 200)
  } catch (err) {
    console.error('capture-error unexpected error', err)
    return jsonResponse({ error: 'internal', message: 'Internal server error' }, 500)
  }
})