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
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return jsonResponse({ error: { code: 'validation_error', message: 'Only POST is supported' } }, 400)

  const authHeader = req.headers.get('Authorization')
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  if (!authHeader || !supabaseUrl || !anonKey) {
    return jsonResponse({ error: { code: 'unauthorized', message: 'Authentication is required' } }, 401)
  }

  try {
    const client = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    })
    const body = await req.json() as { series_id?: string }
    if (!body.series_id) {
      return jsonResponse({ error: { code: 'validation_error', message: 'series_id is required' } }, 400)
    }

    const { data, error } = await client.rpc('publish_event_series', {
      p_series_id: body.series_id,
    })
    if (error) {
      return jsonResponse({ error: { code: 'validation_error', message: error.message } }, 400)
    }

    return jsonResponse({ success: true, series: data }, 200)
  } catch (error) {
    console.error('publish-event-series error:', error)
    return jsonResponse({ error: { code: 'internal_error', message: 'An unexpected error occurred' } }, 500)
  }
})
