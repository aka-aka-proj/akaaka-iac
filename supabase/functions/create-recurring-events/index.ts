import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { generateRecurringDates, validateRecurrenceRule } from '../_shared/recurrence.ts'
import type { RecurrenceRule } from '../_shared/recurrence.ts'

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

function errorResponse(code: string, message: string, status: number): Response {
  return jsonResponse({ error: { code, message } }, status)
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return errorResponse('validation_error', 'Only POST is supported', 400)

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return errorResponse('unauthorized', 'Missing authorization header', 401)

    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      console.error('create-recurring-events missing Supabase environment')
      return errorResponse('internal_error', 'Server configuration is incomplete', 500)
    }

    const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } } })
    const { data: { user }, error: authError } = await userClient.auth.getUser()
    if (authError || !user) return errorResponse('unauthorized', 'Invalid or expired token', 401)

    const body = await req.json() as {
      parent_event_id?: string
      recurrence_rule?: RecurrenceRule
      start_time?: string
    }
    const parentEventId = body.parent_event_id
    const rule = body.recurrence_rule
    const baseDate = body.start_time ? new Date(body.start_time) : null

    if (!parentEventId || !rule || !baseDate || Number.isNaN(baseDate.getTime())) {
      return errorResponse('validation_error', 'parent_event_id, recurrence_rule, and valid start_time are required', 400)
    }
    const validationError = validateRecurrenceRule(rule)
    if (validationError) return errorResponse('validation_error', validationError, 400)
    if (rule.until && new Date(rule.until) < baseDate) {
      return errorResponse('validation_error', 'until must not be earlier than start_time', 400)
    }

    const serviceClient = createClient(supabaseUrl, serviceRoleKey)
    const { data: parentEvent, error: parentError } = await serviceClient.from('events').select('*').eq('id', parentEventId).single()
    if (parentError || !parentEvent) return errorResponse('not_found', 'Parent event not found', 404)
    if (parentEvent.creator_id !== user.id) return errorResponse('forbidden', 'Only the event host can create recurring events', 403)

    const dates = generateRecurringDates(baseDate, rule)
    const instanceIds = [parentEventId]
    let failedInstanceCount = 0

    for (const nextDate of dates) {
      const { data: instance, error: insertError } = await serviceClient.from('events').insert([{
        creator_id: parentEvent.creator_id,
        title: parentEvent.title,
        description: parentEvent.description,
        category: parentEvent.category || 'Social',
        event_type: parentEvent.event_type,
        is_venue_hosted: parentEvent.is_venue_hosted,
        visibility_settings: parentEvent.visibility_settings,
        registration_form_config: parentEvent.registration_form_config,
        recurrence_rule: rule,
        series_id: parentEventId,
        start_time: nextDate.toISOString(),
        location_region: parentEvent.location_region,
        location_detail: parentEvent.location_detail,
        max_capacity: parentEvent.max_capacity,
        registration_deadline: parentEvent.registration_deadline,
        external_registration_url: parentEvent.external_registration_url,
        source_url: parentEvent.source_url,
      }]).select('id').single()

      if (insertError || !instance) {
        failedInstanceCount += 1
        console.error('Failed to create recurring instance', { parentEventId, startTime: nextDate.toISOString(), error: insertError })
        continue
      }
      instanceIds.push(instance.id)
    }

    const createdInstanceCount = instanceIds.length - 1
    console.info('create-recurring-events completed', {
      parentEventId,
      requestedInstanceCount: dates.length,
      createdInstanceCount,
      failedInstanceCount,
    })
    return jsonResponse({
      success: failedInstanceCount === 0,
      parent_id: parentEventId,
      instance_count: instanceIds.length,
      created_instance_count: createdInstanceCount,
      failed_instance_count: failedInstanceCount,
      instance_ids: instanceIds,
    }, 200)
  } catch (err) {
    console.error('create-recurring-events unexpected error', err)
    return errorResponse('internal_error', 'Internal server error', 500)
  }
})
