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

interface RecurrenceRule {
  frequency: 'weekly' | 'monthly'
  interval: number
  days?: string[]
  count?: number
  until?: string
}

const DAY_MAP: Record<string, number> = {
  Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 0,
}

function computeNextDate(base: Date, frequency: 'weekly' | 'monthly', interval: number, days: string[], occurrence: number): Date | null {
  if (frequency === 'weekly') {
    const targetDayNumbers = days.map((d) => DAY_MAP[d]).filter((d) => d !== undefined)
    if (targetDayNumbers.length === 0) return null

    const result = new Date(base)
    // Move to the start of the week containing the base date
    result.setDate(result.getDate() + (occurrence - 1) * 7 * interval)

    // Find the first target day in the current week
    let found = false
    for (let weekOffset = 0; weekOffset < 7 && !found; weekOffset++) {
      for (const dayNum of targetDayNumbers.sort()) {
        const candidate = new Date(base)
        candidate.setDate(candidate.getDate() + weekOffset * 7 * interval + ((dayNum - base.getDay() + 7) % 7))
        if (candidate > base) {
          return candidate
        }
      }
    }
    return null
  }

  if (frequency === 'monthly') {
    const result = new Date(base)
    result.setMonth(result.getMonth() + occurrence * interval)
    return result
  }

  return null
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

    const body = (await req.json()) as {
      parent_event_id?: string
      recurrence_rule?: RecurrenceRule
      start_time?: string
    }

    const parentEventId = body.parent_event_id
    const rule = body.recurrence_rule
    const startTimeStr = body.start_time

    if (!parentEventId || !rule || !startTimeStr) {
      return jsonResponse({ error: 'invalid', message: 'parent_event_id, recurrence_rule, and start_time are required' }, 400)
    }

    if (rule.frequency !== 'weekly' && rule.frequency !== 'monthly') {
      return jsonResponse({ error: 'invalid', message: 'frequency must be "weekly" or "monthly"' }, 400)
    }

    const serviceClient = createClient(supabaseUrl, serviceRoleKey)

    // Fetch the parent event
    const { data: parentEvent, error: parentError } = await serviceClient
      .from('events')
      .select('*')
      .eq('id', parentEventId)
      .single()

    if (parentError || !parentEvent) {
      return jsonResponse({ error: 'not_found', message: 'Parent event not found' }, 404)
    }

    // Verify caller is the event host
    if (parentEvent.creator_id !== user.id) {
      return jsonResponse({ error: 'forbidden', message: 'Only the event host can create recurring events' }, 403)
    }

    const totalCount = rule.count ?? 4
    // First instance is the parent event itself
    const instanceCount = Math.max(0, totalCount - 1)

    if (instanceCount <= 0) {
      return jsonResponse({ success: true, parent_id: parentEventId, instance_count: 1, instance_ids: [parentEventId] }, 200)
    }

    const baseDate = new Date(startTimeStr)
    const days = rule.days ?? ['Mon']
    const instanceIds: string[] = []

    for (let i = 1; i <= instanceCount; i++) {
      const nextDate = computeNextDate(baseDate, rule.frequency, rule.interval || 1, days, i)
      if (!nextDate) continue

      // Check until limit
      if (rule.until && nextDate > new Date(rule.until)) continue

      const { data: instance, error: insertError } = await serviceClient
        .from('events')
        .insert([{
          creator_id: parentEvent.creator_id,
          title: parentEvent.title,
          description: parentEvent.description,
          category: parentEvent.category || 'Social',
          event_type: parentEvent.event_type,
          is_venue_hosted: parentEvent.is_venue_hosted,
          visibility_settings: parentEvent.visibility_settings,
          registration_form_config: parentEvent.registration_form_config,
          recurrence_rule: parentEvent.recurrence_rule,
          series_id: parentEventId,
          start_time: nextDate.toISOString(),
          location_region: parentEvent.location_region,
          location_detail: parentEvent.location_detail,
          max_capacity: parentEvent.max_capacity,
          registration_deadline: parentEvent.registration_deadline,
        }])
        .select('id')
        .single()

      if (insertError) {
        console.error('Failed to create recurring instance', insertError)
        continue
      }

      instanceIds.push(instance.id)
    }

    return jsonResponse({
      success: true,
      parent_id: parentEventId,
      instance_count: instanceIds.length + 1,
      instance_ids: [parentEventId, ...instanceIds],
    }, 200)
  } catch (err) {
    console.error('create-recurring-events unexpected error', err)
    return jsonResponse({ error: 'internal', message: 'Internal server error' }, 500)
  }
})