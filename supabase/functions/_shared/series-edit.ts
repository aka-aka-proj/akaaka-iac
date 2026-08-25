// No direct imports needed — pure functions work with plain objects.
// RecurrenceRule type is referenced only via the RecurrenceRule import in
// _index.ts which calls into this module's Record-based functions.

export type SeriesScope = 'rest_of_series' | 'entire_series'

export type DeadlineAction = 'keep' | 'reapply_offset' | 'set_absolute'

export interface DeadlineParams {
  offset_minutes?: number
  absolute?: string
}

export interface SeriesMemberRow {
  id: string
  series_id: string | null
  start_time: string
  lifecycle_status: string
  creator_id: string
  [key: string]: unknown
}

export interface SeriesResolution {
  parentId: string
  parentStartTime: string
  parentLifecycleStatus: string
  children: SeriesMemberRow[]
}

/**
 * Resolve series membership from a target event.
 * Returns the parent id and all children. Does NOT re-fetch the parent row;
 * the caller must provide the full parent row (fetched independently).
 */
export function resolveSeriesMembers(
  target: { series_id: string | null; id: string },
  parentRow: SeriesMemberRow | null,
  children: SeriesMemberRow[],
): SeriesResolution | null {
  // target is a parent (series_id is null, and children exist)
  if (target.series_id === null && children.length > 0) {
    if (!parentRow) return null
    return {
      parentId: parentRow.id,
      parentStartTime: parentRow.start_time,
      parentLifecycleStatus: parentRow.lifecycle_status,
      children: children.filter((c) => c.id !== parentRow.id),
    }
  }
  // target is a child (series_id is set)
  if (target.series_id !== null) {
    if (!parentRow) return null
    return {
      parentId: parentRow.id,
      parentStartTime: parentRow.start_time,
      parentLifecycleStatus: parentRow.lifecycle_status,
      children: [target as SeriesMemberRow, ...children.filter((c) => c.id !== target.id && c.id !== parentRow.id)],
    }
  }
  // standalone event (no series relationship)
  return null
}

/**
 * Returns all members (parent included) that should be updated according to the scope.
 * start_time comparison is ISO string (valid since all are UTC ISO timestamps).
 */
export function filterScopeMembers(
  parent: SeriesMemberRow,
  children: SeriesMemberRow[],
  scope: SeriesScope,
  targetStartTime: string,
): SeriesMemberRow[] {
  const all = [parent, ...children]
  if (scope === 'entire_series') return all
  // rest_of_series: target + all members with start_time >= target
  return all.filter((m) => m.start_time >= targetStartTime)
}

/**
 * Lock predicate: never update a non-draft event that has started or is terminal.
 * @param nowIso — ISO timestamp string for "now", e.g. new Date().toISOString()
 */
export function isLocked(event: { lifecycle_status: string; start_time: string }, nowIso: string): boolean {
  if (event.lifecycle_status === 'draft') return false
  if (['completed', 'archived', 'cancelled'].includes(event.lifecycle_status)) return true
  return event.start_time <= nowIso
}

/**
 * Compute the next registration_deadline for a single member.
 * Returns undefined when the deadline should stay unchanged (keep).
 * Returns null when it should be set to null (set_absolute with null value).
 */
export function computeNextDeadline(
  memberStartTime: string,
  action: DeadlineAction,
  params: DeadlineParams,
): string | null | undefined {
  if (action === 'keep') return undefined
  if (action === 'set_absolute') {
    return params.absolute ?? null
  }
  // reapply_offset
  const startMs = new Date(memberStartTime).getTime()
  return new Date(startMs - (params.offset_minutes ?? 0) * 60000).toISOString()
}

/**
 * Compute the new recurrence_rule JSON for the parent row after a deadline action.
 * Returns:
 *   - null: no change needed (keep action, or action with no existing rule)
 *   - undefined: remove the offset key from the rule (set_absolute)
 *   - a Record<string, unknown>: the rule with offset set (reapply_offset)
 */
export function computeTemplateRuleUpdate(
  existingRule: Record<string, unknown> | null,
  action: DeadlineAction,
  params: DeadlineParams,
): Record<string, unknown> | null | undefined {
  if (action === 'keep') return null
  if (action === 'set_absolute') {
    if (existingRule === null) return null
    const updated = { ...existingRule }
    delete updated.registration_deadline_offset_minutes
    // If nothing changed after removing the key, return null (no-op)
    return JSON.stringify(updated) === JSON.stringify(existingRule) ? null : updated
  }
  // reapply_offset
  const updated = { ...(existingRule ?? {}), registration_deadline_offset_minutes: params.offset_minutes }
  return JSON.stringify(updated) === JSON.stringify(existingRule) ? null : updated
}

/**
 * Compare a set of field values against the current row values.
 * The `whitelist` defines which top-level keys in `fields` are accepted.
 * Returns the subset of fields that actually differ from the row.
 */
export function diffEditableFields(
  fields: Record<string, unknown>,
  row: Record<string, unknown>,
  whitelist: Set<string>,
): Record<string, unknown> {
  const diffs: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(fields)) {
    if (!whitelist.has(key)) continue
    const current = row[key]
    // Compare by JSON for deep types (arrays, JSONB)
    if (JSON.stringify(value) !== JSON.stringify(current)) {
      diffs[key] = value
    }
  }
  return diffs
}

/**
 * Validate that fields contain only whitelisted keys (no scheduling fields,
 * no disallowed provenance/system fields).
 * Returns error message or null.
 */
export function validateEditableFields(
  fields: Record<string, unknown> | undefined,
): string | null {
  if (fields === undefined || fields === null) return null
  const disallowed = ['start_time', 'recurrence_rule', 'source_url', 'is_venue_hosted']
  for (const key of Object.keys(fields)) {
    if (disallowed.includes(key)) {
      return `field "${key}" is not allowed in batch edits`
    }
  }
  return null
}

export const BATCH_FIELDS_WHITELIST = new Set([
  'title', 'description', 'category', 'event_type',
  'location_region', 'location_detail',
  'max_capacity', 'attendance_fee_type', 'attendance_fee_amount',
  'visibility_settings', 'registration_form_config', 'external_registration_url',
])