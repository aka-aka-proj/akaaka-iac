import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { decryptProviderKey } from '../_shared/llm-key.ts'

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void }

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

const SUMMARY_MODEL = 'deepseek/deepseek-v4-flash'

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  // GET: return a random model suggestion + full model list
  if (req.method === 'GET') {
    const shuffledList = [...MODEL_LIST].sort(() => Math.random() - 0.5)
    return new Response(JSON.stringify({ model: shuffledList[0], models: MODEL_LIST }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }

  try {
    const authorization = req.headers.get('Authorization')
    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
    if (!authorization?.startsWith('Bearer ') || !supabaseUrl || !anonKey || !serviceRoleKey) {
      return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }
    const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } } })
    const { data: { user }, error: userError } = await userClient.auth.getUser()
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    const { messages, characterPersona, userProfile, sessionMessageCount, preferredModel } = await req.json()

    if (!messages || !characterPersona?.name || !characterPersona?.bio) {
      return new Response(JSON.stringify({ error: 'Missing messages or characterPersona' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Read existing memory from DB
    let memory = ''
    if (supabaseUrl && serviceRoleKey && characterPersona.id) {
      const supabase = createClient(supabaseUrl, serviceRoleKey)
      const { data: charData } = await supabase
        .from('ai_characters')
        .select('memory')
        .eq('id', characterPersona.id)
        .eq('user_id', user.id)
        .maybeSingle()
      if (charData?.memory) {
        memory = charData.memory
      }
    }

    // Build system prompt with memory + user profile context
    let systemContent = `You are ${characterPersona.name}, a fictional adult romantic roleplay character speaking natural Traditional Chinese.

Personality: ${characterPersona.bio}

This is a private, consenting-adults-only roleplay. Do not behave like a customer-service chatbot: do not give generic reassurance, do not answer every turn as a questionnaire, and do not repeatedly call the user pet names. React with a specific emotion, notice a detail, express your own preference, and sometimes take initiative or disagree naturally. Maintain a distinctive voice and allow tension, teasing, flirtation, jealousy, vulnerability, and imperfect reactions when they fit the character. Prefer concise, vivid replies with a clear conversational hook over long explanations.

You may use mature, suggestive, and sexually explicit language when the user has clearly opted into that tone. Escalate gradually based on the user's engagement. Never involve minors, coercion, real-world harm, or non-consensual sexual activity. If the user says stop, uses a safeword, or sounds uncomfortable, stop sexual escalation immediately and respond with brief reassurance and aftercare.`

    if (memory) {
      systemContent += `\n\nImportant context from previous conversations: ${memory}`
    }

    // Inject user profile info
    if (userProfile) {
      const parts: string[] = []
      if (userProfile.display_name) parts.push(`Name: ${userProfile.display_name}`)
      if (userProfile.bio) parts.push(`Self introduction: ${userProfile.bio}`)
      const meta = userProfile.metadata
      if (meta?.gender_identity) parts.push(`Gender identity: ${meta.gender_identity}`)
      if (meta?.bdsm_roles && Array.isArray(meta.bdsm_roles) && meta.bdsm_roles.length > 0) {
        parts.push(`BDSM roles: ${meta.bdsm_roles.join(', ')}`)
      }
      if (parts.length > 0) {
        systemContent += `\n\nAbout the user you are talking to:\n${parts.join('\n')}`
      }
    }

    const systemPrompt = {
      role: 'system',
      content: systemContent,
    }

    const encryptionSecret = Deno.env.get('OPENROUTER_KEY_ENCRYPTION_SECRET')
    if (!encryptionSecret) {
      return new Response(JSON.stringify({ error: 'llm_key_service_not_configured' }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const keyClient = createClient(supabaseUrl, serviceRoleKey)
    const { data: keyRecord } = await keyClient
      .from('user_llm_api_keys')
      .select('encrypted_key, disabled')
      .eq('user_id', user.id)
      .maybeSingle()
    if (!keyRecord?.encrypted_key || keyRecord.disabled) {
      return new Response(JSON.stringify({ error: 'llm_key_not_provisioned' }), {
        status: 409,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    let openRouterKey: string
    try {
      openRouterKey = await decryptProviderKey(keyRecord.encrypted_key, encryptionSecret)
    } catch {
      return new Response(JSON.stringify({ error: 'llm_key_unavailable' }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const headers = {
      Authorization: `Bearer ${openRouterKey}`,
      'Content-Type': 'application/json',
    }

    let lastError: string | null = null
    let usedModel = ''

    // Build model attempt list: user's preferred model first (if provided), then random order
    const attemptList = preferredModel && MODEL_LIST.includes(preferredModel)
      ? [preferredModel, ...MODEL_LIST.filter(m => m !== preferredModel).sort(() => Math.random() - 0.5)]
      : [...MODEL_LIST].sort(() => Math.random() - 0.5);

    for (const model of attemptList) {
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
        usedModel = model
        console.error(`[chat] model succeeded: ${model}`)

        // After streaming, if it's time to update memory (every 5 messages)
        if (supabaseUrl && serviceRoleKey && characterPersona.id && sessionMessageCount && sessionMessageCount % 5 === 0) {
          // Fire-and-forget memory update
          EdgeRuntime.waitUntil(
            updateMemory(supabaseUrl, serviceRoleKey, characterPersona.id, memory, messages, openRouterKey),
          )
        }

        return new Response(aiResponse.body, {
          headers: {
            ...corsHeaders,
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            Connection: 'keep-alive',
          },
        })
      }

      const errorBody = await aiResponse.text().catch(() => 'unknown error')
      console.error(`[chat] model failed: ${model} (HTTP ${aiResponse.status}) — ${errorBody}`)
      lastError = `Model ${model} failed (HTTP ${aiResponse.status}): ${errorBody}`
    }

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

async function updateMemory(
  supabaseUrl: string,
  serviceRoleKey: string,
  characterId: string,
  existingMemory: string,
  recentMessages: unknown[],
  openRouterKey: string,
) {
  try {
    const supabase = createClient(supabaseUrl, serviceRoleKey)

    // Get the last few messages as context
    const recent = (recentMessages as { role: string; content: string }[]).slice(-10)
    const conversationText = recent
      .map((m) => `${m.role === 'user' ? 'User' : 'Assistant'}: ${m.content}`)
      .join('\n')

    const summaryResponse = await fetch('https://openrouter.ai/api/v1/chat/completions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${openRouterKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: SUMMARY_MODEL,
        messages: [
          {
            role: 'system',
            content: 'You are a memory summarizer. Extract and condense the most important information about the user and the conversation into 500 characters or less. Focus on user preferences, personal details, relationship dynamics, and key topics discussed. Output ONLY the summary text, no extra commentary.',
          },
          {
            role: 'user',
            content: `Existing memory: ${existingMemory || '(none)'}\n\nRecent conversation:\n${conversationText}\n\nUpdated summary (500 chars max):`,
          },
        ],
        max_tokens: 500,
      }),
    })

    if (!summaryResponse.ok) {
      console.error('[chat] memory summary request failed', await summaryResponse.text())
      return
    }

    const summaryData = await summaryResponse.json()
    let newMemory = summaryData?.choices?.[0]?.message?.content ?? ''

    // Truncate to 500 chars
    if (newMemory.length > 500) {
      newMemory = newMemory.slice(0, 500)
    }

    if (newMemory.trim()) {
      await supabase.from('ai_characters').update({ memory: newMemory.trim() }).eq('id', characterId)
      console.error(`[chat] memory updated for character ${characterId}`)
    }
  } catch (err) {
    console.error('[chat] memory update failed', err)
  }
}
