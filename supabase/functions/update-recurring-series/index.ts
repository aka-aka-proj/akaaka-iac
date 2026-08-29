import { createClient } from '@supabase/supabase-js'
import {
  resolveSeriesMembers,
  filterScopeMembers,
  isLocked,
  computeNextDeadline,
  computeTemplateRuleUpdate,
  diffEditableFields,
  validateEditableFields,
  BATCH_FIELDS_WHITELIST,
} from '../_shared/series-edit.ts'
import type { SeriesScope, DeadlineAction, DeadlineParams, SeriesMemberRow } from '../_shared/series-edit.ts'

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
      console.error('update-recurring-series missing Supabase environment')
      return errorResponse('internal_error', 'Server configuration is incomplete', 500)
    }

    const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } } })
    const { data: { user }, error: authError } = await userClient.auth.getUser()
    if (authError || !user) return errorResponse('unauthorized', 'Invalid or expired token', 401)

    const body = await req.json() as {
      target_event_id?: string
      scope?: string
      fields?: Record<string, unknown>
      deadline?: { action?: string; offset_minutes?: number; absolute?: string }
    }

    // Validate required fields
    const targetEventId = body.target_event_id
    const scope = body.scope as SeriesScope | undefined
    if (!targetEventId) return errorResponse('validation_error', 'target_event_id is required', 400)
    if (!scope || !['rest_of_series', 'entire_series'].includes(scope)) {
      return errorResponse('validation_error', 'scope must be "rest_of_series" or "entire_series"', 400)
    }

    // Validate deadline action
    const deadlineAction = (body.deadline?.action ?? 'keep') as DeadlineAction
    if (!['keep', 'reapply_offset', 'set_absolute'].includes(deadlineAction)) {
      return errorResponse('validation_error', 'deadline.action must be "keep", "reapply_offset", or "set_absolute"', 400)
    }
    const deadlineParams: DeadlineParams = {
      offset_minutes: body.deadline?.offset_minutes,
      absolute: body.deadline?.absolute,
    }
    if (deadlineAction === 'reapply_offset') {
      if (!Number.isInteger(deadlineParams.offset_minutes) || deadlineParams.offset_minutes! < 1 || deadlineParams.offset_minutes! > 525600) {
        return errorResponse('validation_error', 'deadline.offset_minutes must be an integer between 1 and 525600', 400)
      }
    }
    if (deadlineAction === 'set_absolute') {
      if (!deadlineParams.absolute || Number.isNaN(new Date(deadlineParams.absolute).getTime())) {
        return errorResponse('validation_error', 'deadline.absolute must be a valid UTC timestamp', 400)
      }
    }

    // Validate fields (if provided)
    if (body.fields !== undefined) {
      const fieldErr = validateEditableFields(body.fields)
      if (fieldErr) return errorResponse('validation_error', fieldErr, 400)
    }

    // At least one change must be present
    const hasFieldChanges = body.fields !== undefined && Object.keys(body.fields).length > 0
    const hasDeadlineChanges = deadlineAction !== 'keep'
    if (!hasFieldChanges && !hasDeadlineChanges) {
      return errorResponse('validation_error', 'provide at least one field to update or a non-keep deadline action', 400)
    }

    const serviceClient = createClient(supabaseUrl, serviceRoleKey)
    // Fetch target event
    const { data: target, error: targetError } = await serviceClient.from('events')
      .select('id, series_id, start_time, lifecycle_status, creator_id')
      .eq('id', targetEventId).single()
    if (targetError || !target) return errorResponse('not_found', 'Target event not found', 404)

    // Resolve series membership
    const parentId = target.series_id ?? target.id
    const { data: parent, error: parentError } = await serviceClient.from('events').select('*').eq('id', parentId).single()
    if (parentError || !parent) return errorResponse('not_found', 'Series parent event not found', 404)

    const { data: children, error: childrenError } = await serviceClient.from('events').select('*').eq('series_id', parentId)
    if (childrenError) return errorResponse('internal_error', 'Failed to fetch series members', 500)

    const resolution = resolveSeriesMembers(target, parent, children ?? [])
    if (!resolution) {
      return errorResponse('validation_error', 'Target event is not part of a recurring series', 400)
    }

    // Authorization: caller must be the creator of all series members
    if (parent.creator_id !== user.id) {
      return errorResponse('forbidden', 'Only the event host can edit this series', 403)
    }
    for (const child of resolution.children) {
      if (child.creator_id !== user.id) {
        return errorResponse('forbidden', 'Only the event host can edit this series', 403)
      }
    }

    // Derive is_venue_hosted from caller's profile
    const { data: profile, error: profileError } = await serviceClient.from('profiles').select('role_status').eq('id', user.id).single()
    if (profileError || !profile) {
      console.error('Failed to fetch caller profile for venue flag', { userId: user.id, error: profileError })
      return errorResponse('internal_error', 'Failed to verify venue status', 500)
    }
    const derivedVenueHosted = profile.role_status === 'venue_approved'

    // Filter scope members
    const scopeMembers = filterScopeMembers(parent as SeriesMemberRow, (children ?? []) as SeriesMemberRow[], scope, target.start_time)

    // Process each member
    let updatedCount = 0
    let skippedLockedCount = 0
    let failedCount = 0
    const updatedEventIds: string[] = []

    for (const member of scopeMembers) {
      const currentNowIso = new Date().toISOString()
      if (isLocked(member, currentNowIso)) {
        skippedLockedCount += 1
        continue
      }

      // Build update object
      const updateObject: Record<string, unknown> = {}

      // Content fields (with diff check)
      if (body.fields && Object.keys(body.fields).length > 0) {
        const diffs = diffEditableFields(body.fields, member, BATCH_FIELDS_WHITELIST)
        for (const [key, value] of Object.entries(diffs)) {
          updateObject[key] = value
        }
      }

      // Derived venue flag (always apply when member is being updated)
      if (member.is_venue_hosted !== derivedVenueHosted) {
        updateObject.is_venue_hosted = derivedVenueHosted
      }

      // Deadline
      if (deadlineAction !== 'keep') {
        const nextDeadline = computeNextDeadline(member.start_time, deadlineAction, deadlineParams)
        const currentMs = member.registration_deadline ? new Date(member.registration_deadline).getTime() : null
        const nextMs = nextDeadline ? new Date(nextDeadline).getTime() : null
        if (currentMs !== nextMs) {
          updateObject.registration_deadline = nextDeadline ?? null
        }
      }

      // Skip if nothing changed or member is locked
      if (Object.keys(updateObject).length === 0) continue

      // Re-check lock predicate at write time to handle stale data
      // (member may have started between fetch and update).
      const { error: updateError } = await serviceClient.from('events')
        .update(updateObject)
        .eq('id', member.id)
        .not('lifecycle_status', 'in', '("completed","archived","cancelled")')
        .or(`lifecycle_status.eq.draft,start_time.gt.${currentNowIso}`)

      if (updateError) {
        failedCount += 1
        console.error('Failed to update series member', { memberId: member.id, error: updateError })
        continue
      }
      updatedCount += 1
      updatedEventIds.push(member.id)
    }

// Template sync (only for deadline actions that modify the rule)
    let templateSyncSkipped = false
    if (deadlineAction !== 'keep') {
      if (isLocked(parent as SeriesMemberRow, new Date().toISOString())) {
        templateSyncSkipped = true
      } else {
        const newRule = computeTemplateRuleUpdate(parent.recurrence_rule, deadlineAction, deadlineParams)
        if (newRule !== null) {
          const { error: ruleError } = await serviceClient.from('events')
            .update({ recurrence_rule: newRule ?? undefined })
            .eq('id', parentId)
          if (ruleError) {
            console.error('Failed to sync deadline template to parent', { parentId, error: ruleError })
            failedCount += 1
          }
        }
      }
    }

    return jsonResponse({
      success: failedCount === 0,
      updated_count: updatedCount,
      skipped_locked_count: skippedLockedCount,
      failed_count: failedCount,
      updated_event_ids: updatedEventIds,
      template_sync_skipped: templateSyncSkipped,
    }, 200)
  } catch (err) {
    console.error('update-recurring-series unexpected error', err)
    return errorResponse('internal_error', 'Internal server error', 500)
  }
})
