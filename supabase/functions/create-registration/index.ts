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

    const body = (await req.json()) as { event_id?: string; form_responses?: Record<string, unknown> }
    const eventId = body.event_id
    const formResponses = body.form_responses

    if (!eventId) {
      return jsonResponse({ error: 'invalid', message: 'event_id is required' }, 400)
    }

    const serviceClient = createClient(supabaseUrl, serviceRoleKey)

    // 1. Fetch event
    const { data: event, error: eventError } = await serviceClient
      .from('events')
      .select('id, creator_id, max_capacity, registration_deadline, external_registration_url')
      .eq('id', eventId)
      .single()

    if (eventError || !event) {
      return jsonResponse({ error: 'not_found', message: 'Event not found' }, 404)
    }

    if (event.external_registration_url) {
      return jsonResponse({ error: 'external_registration', message: 'This event uses an external registration form' }, 400)
    }

    // 2. Host cannot register for own event
    if (event.creator_id === user.id) {
      return jsonResponse({ error: 'host_cannot_register', message: 'Event host cannot register for their own event' }, 400)
    }

    // 3. Registration deadline check
    if (event.registration_deadline && new Date(event.registration_deadline) < new Date()) {
      return jsonResponse({ error: 'registration_closed', message: 'Registration deadline has passed' }, 400)
    }

    // 4. Block check (bidirectional)
    const { data: blocks } = await serviceClient
      .from('blocks')
      .select('blocker_id, blocked_id')
      .or(`and(blocker_id.eq.${user.id},blocked_id.eq.${event.creator_id}),and(blocker_id.eq.${event.creator_id},blocked_id.eq.${user.id})`)

    if (blocks && blocks.length > 0) {
      const block = blocks[0]
      const message = block.blocker_id === user.id 
        ? 'You have blocked this event host.' 
        : 'This event host has blocked you.'
      return jsonResponse({ error: 'blocked', message }, 403)
    }

    // 5. Check existing active registration
    const { data: existing } = await serviceClient
      .from('event_registrations')
      .select('id, status')
      .eq('event_id', eventId)
      .eq('profile_id', user.id)
      .neq('status', 'cancelled')
      .maybeSingle()

    if (existing) {
      return jsonResponse({ error: 'already_registered', message: 'You already have an active registration for this event' }, 400)
    }

    // 5b. Validate form responses if event has a form config
    if (formResponses) {
      const { data: eventFormConfig } = await serviceClient
        .from('events')
        .select('registration_form_config')
        .eq('id', eventId)
        .single()

      if (eventFormConfig?.registration_form_config) {
        const config = eventFormConfig.registration_form_config as Array<{ id: string; required?: boolean; type: string; options?: string[] }>
        for (const field of config) {
          if (field.required) {
            const val = formResponses[field.id]
            if (val === undefined || val === null || val === '' || val === false) {
              return jsonResponse({ error: 'form_validation_error', message: `Required field '${field.id}' is missing` }, 400)
            }
          }
          if (field.type === 'select' && field.options && formResponses[field.id]) {
            if (!field.options.includes(formResponses[field.id] as string)) {
              return jsonResponse({ error: 'form_validation_error', message: `Invalid value for field '${field.id}'` }, 400)
            }
          }
        }
      }
    }

    // 6. Recheck capacity and insert under the same event-row lock used by
    // series registration. The earlier capacity read is UX-only.
    const { data: rawReg, error: regError } = await serviceClient
      .rpc('create_event_registration_atomic', { p_event_id: eventId, p_profile_id: user.id })
      .single()
    const reg = rawReg as unknown as {
      id: string
      event_id: string
      status: string
      waitlist_position: number | null
      created_at: string
    } | null

    if (regError || !reg) {
      const message = regError?.message ?? 'Failed to create registration'
      if (message.includes('already registered')) {
        return jsonResponse({ error: 'already_registered', message: 'You already have an active registration for this event' }, 400)
      }
      return jsonResponse({ error: 'db_error', message }, 500)
    }

    // 8. Insert form responses if provided
    let regResponses = null
    if (formResponses && reg) {
      const { data: respData, error: respError } = await serviceClient
        .from('event_registration_responses')
        .insert([{
          registration_id: reg.id,
          responses: formResponses,
        }])
        .select('id, responses')
        .single()

      if (respError) {
        // Log but don't fail the registration - form responses are supplementary
        console.error('Failed to insert form responses', respError)
      } else {
        regResponses = respData
      }
    }

    return jsonResponse({ success: true, registration: reg, form_responses: regResponses }, 200)
  } catch (err) {
    console.error('create-registration unexpected error', err)
    return jsonResponse({ error: 'internal', message: 'Internal server error' }, 500)
  }
})
