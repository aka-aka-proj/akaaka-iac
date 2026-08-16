const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MODEL_LIST = [
  'aion-labs/aion-3.0-mini',
  'minimax/minimax-m2-her',
  'cognitivecomputations/dolphin-mistral-24b-venice-edition',
  'deepseek/deepseek-v4-flash',
]

// Issue #77: the legacy server chat route is intentionally disabled. Browser
// direct provider requests are the only steady-state path so this function
// cannot read, log, summarize, or write prompt/completion/memory plaintext.
Deno.serve((req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  if (req.method === 'GET') {
    return new Response(JSON.stringify({ model: MODEL_LIST[0], models: MODEL_LIST }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  return new Response(JSON.stringify({ error: 'browser_direct_only' }), {
    status: 410,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
})
