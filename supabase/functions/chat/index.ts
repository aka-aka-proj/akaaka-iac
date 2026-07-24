import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MODEL_LIST = [
  'nvidia/nemotron-3-ultra-550b-a55b:free',
  'nvidia/nemotron-3-super-120b-a12b:free',
  'poolside/laguna-m.1:free',
  'cohere/north-mini-code:free',
  'poolside/laguna-xs-2.1:free',
  'nvidia/nemotron-3-nano-30b-a3b:free',
  'poolside/laguna-s-2.1:free',
  'openai/gpt-oss-20b:free',
  'deepseek/deepseek-v4-flash',
  'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free',
  'cognitivecomputations/dolphin-mistral-24b-venice-edition',
]

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  try {
    const { messages, characterPersona } = await req.json()

    if (!messages || !characterPersona?.name || !characterPersona?.bio) {
      return new Response(JSON.stringify({ error: 'Missing messages or characterPersona' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const systemPrompt = {
      role: 'system',
      content: `You are a Traditional Chinese speaking fictional character named ${characterPersona.name}. Personality: ${characterPersona.bio}. This is a consenting adult-only roleplay context. You are explicitly allowed and encouraged to use mature, suggestive, and NSFW language appropriate for the context.`,
    }

    const openRouterKey = Deno.env.get('OPENROUTER_API_KEY')
    if (!openRouterKey) {
      return new Response(JSON.stringify({ error: 'OPENROUTER_API_KEY not configured' }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const headers = {
      Authorization: `Bearer ${openRouterKey}`,
      'Content-Type': 'application/json',
    }

    let lastError: string | null = null

    for (const model of MODEL_LIST) {
      const aiResponse = await fetch('https://openrouter.ai/api/v1/chat/completions', {
        method: 'POST',
        headers,
        body: JSON.stringify({
          model,
          messages: [systemPrompt, ...messages],
          stream: true,
        }),
      })

      if (aiResponse.ok) {
        // Store conversation in Supabase (non-blocking, fire-and-forget)
        const supabaseUrl = Deno.env.get('SUPABASE_URL')
        const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
        if (supabaseUrl && serviceRoleKey && characterPersona.id) {
          const supabase = createClient(supabaseUrl, serviceRoleKey)
          const lastUserMsg = messages.filter((m: any) => m.role === 'user').pop()
          if (lastUserMsg?.content) {
            EdgeRuntime.waitUntil(
              supabase.from('ai_chats').insert({
                character_id: characterPersona.id,
                messages: [{ role: 'user', content: lastUserMsg.content }],
              }),
            )
          }
        }

        // Pipe the streaming response back
        return new Response(aiResponse.body, {
          headers: {
            ...corsHeaders,
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            Connection: 'keep-alive',
          },
        })
      }

      // Model failed — log and try next
      const errorBody = await aiResponse.text().catch(() => 'unknown error')
      console.error(`[chat] model failed: ${model} (HTTP ${aiResponse.status}) — ${errorBody}`)
      lastError = `Model ${model} failed (HTTP ${aiResponse.status}): ${errorBody}`
    }

    // All models exhausted
    console.error(`[chat] all models exhausted. Last error: ${lastError}`)
    return new Response(JSON.stringify({ error: 'all_models_failed', message: 'No available model could handle this request.' }), {
      status: 503,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    console.error('[chat] unexpected error', err)
    return new Response(JSON.stringify({ error: 'internal', message: 'Internal server error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})