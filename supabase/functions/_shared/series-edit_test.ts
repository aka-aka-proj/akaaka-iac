import {
  resolveSeriesMembers,
  filterScopeMembers,
  isLocked,
  computeNextDeadline,
  computeTemplateRuleUpdate,
  diffEditableFields,
  validateEditableFields,
  BATCH_FIELDS_WHITELIST,
} from './series-edit.ts'

function assertEquals<T>(actual: T, expected: T): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
  }
}

const nowIso = '2026-09-01T12:00:00.000Z'

// resolveSeriesMembers

Deno.test('resolveSeriesMembers returns null for standalone event', () => {
  assertEquals(resolveSeriesMembers({ series_id: null, id: 's1' }, null, []), null)
})

Deno.test('resolveSeriesMembers resolves parent with children', () => {
  const parent = { id: 'p1', series_id: null, start_time: '2026-09-01T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' }
  const children = [
    { id: 'c1', series_id: 'p1', start_time: '2026-09-07T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' },
    { id: 'c2', series_id: 'p1', start_time: '2026-09-14T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' },
  ]
  const result = resolveSeriesMembers({ series_id: null, id: 'p1' }, parent, children)
  assertEquals(result?.parentId, 'p1')
  assertEquals(result?.children.length, 2)
})

Deno.test('resolveSeriesMembers resolves child with parent', () => {
  const parent = { id: 'p1', series_id: null, start_time: '2026-09-01T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' }
  const children = [
    { id: 'c1', series_id: 'p1', start_time: '2026-09-07T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' },
    { id: 'c2', series_id: 'p1', start_time: '2026-09-14T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' },
  ]
  const result = resolveSeriesMembers({ series_id: 'p1', id: 'c1' }, parent, children)
  assertEquals(result?.parentId, 'p1')
  assertEquals(result?.children.length, 2)
})

// filterScopeMembers

Deno.test('filterScopeMembers entire_series includes all', () => {
  const parent = { id: 'p1', series_id: null, start_time: '2026-09-01T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' }
  const children = [
    { id: 'c1', series_id: 'p1', start_time: '2026-09-07T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' },
    { id: 'c2', series_id: 'p1', start_time: '2026-09-14T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' },
  ]
  const result = filterScopeMembers(parent, children, 'entire_series', '')
  assertEquals(result.length, 3)
})

Deno.test('filterScopeMembers rest_of_series filters by start_time', () => {
  const parent = { id: 'p1', series_id: null, start_time: '2026-09-01T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' }
  const children = [
    { id: 'c1', series_id: 'p1', start_time: '2026-09-07T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' },
    { id: 'c2', series_id: 'p1', start_time: '2026-09-14T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' },
  ]
  const result = filterScopeMembers(parent, children, 'rest_of_series', '2026-09-10T00:00:00Z')
  assertEquals(result.length, 1)
  assertEquals(result[0].id, 'c2')
})

Deno.test('filterScopeMembers rest_of_series includes target with equal start_time', () => {
  const parent = { id: 'p1', series_id: null, start_time: '2026-09-01T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' }
  const children = [
    { id: 'c1', series_id: 'p1', start_time: '2026-09-07T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' },
    { id: 'c2', series_id: 'p1', start_time: '2026-09-14T12:00:00Z', lifecycle_status: 'draft', creator_id: 'u1' },
  ]
  const result = filterScopeMembers(parent, children, 'rest_of_series', '2026-09-07T12:00:00Z')
  assertEquals(result.length, 2)
  assertEquals(result[0].id, 'c1')
  assertEquals(result[1].id, 'c2')
})

// isLocked

Deno.test('isLocked draft is never locked', () => {
  assertEquals(isLocked({ lifecycle_status: 'draft', start_time: '2026-01-01T00:00:00Z' }, nowIso), false)
})

Deno.test('isLocked terminal states are locked', () => {
  assertEquals(isLocked({ lifecycle_status: 'completed', start_time: '2099-01-01T00:00:00Z' }, nowIso), true)
  assertEquals(isLocked({ lifecycle_status: 'archived', start_time: '2099-01-01T00:00:00Z' }, nowIso), true)
  assertEquals(isLocked({ lifecycle_status: 'cancelled', start_time: '2099-01-01T00:00:00Z' }, nowIso), true)
})

Deno.test('isLocked non-draft past event is locked', () => {
  assertEquals(isLocked({ lifecycle_status: 'published', start_time: '2026-01-01T00:00:00Z' }, nowIso), true)
})

Deno.test('isLocked non-draft future event is not locked', () => {
  assertEquals(isLocked({ lifecycle_status: 'published', start_time: '2026-12-01T00:00:00Z' }, nowIso), false)
})

// computeNextDeadline

Deno.test('computeNextDeadline keep returns undefined', () => {
  assertEquals(computeNextDeadline('2026-09-07T12:00:00.000Z', 'keep', {}), undefined)
})

Deno.test('computeNextDeadline reapply_offset computes correct value', () => {
  assertEquals(computeNextDeadline('2026-09-07T12:00:00.000Z', 'reapply_offset', { offset_minutes: 1440 }), '2026-09-06T12:00:00.000Z')
})

Deno.test('computeNextDeadline set_absolute returns the given absolute', () => {
  assertEquals(computeNextDeadline('2026-09-07T12:00:00.000Z', 'set_absolute', { absolute: '2026-09-05T23:59:59Z' }), '2026-09-05T23:59:59Z')
})

// computeTemplateRuleUpdate

Deno.test('computeTemplateRuleUpdate keep returns null', () => {
  assertEquals(computeTemplateRuleUpdate({ frequency: 'weekly' }, 'keep', {}), null)
})

Deno.test('computeTemplateRuleUpdate set_absolute removes offset key', () => {
  const rule = { frequency: 'weekly', interval: 1, days: ['Mon'], count: 4, timezone: 'Asia/Taipei', registration_deadline_offset_minutes: 1440 }
  const result = computeTemplateRuleUpdate(rule, 'set_absolute', {})
  assertEquals(result, { frequency: 'weekly', interval: 1, days: ['Mon'], count: 4, timezone: 'Asia/Taipei' })
})

Deno.test('computeTemplateRuleUpdate set_absolute on null rule returns null', () => {
  assertEquals(computeTemplateRuleUpdate(null, 'set_absolute', {}), null)
})

Deno.test('computeTemplateRuleUpdate set_absolute on rule without offset returns null', () => {
  const rule = { frequency: 'weekly', interval: 1, days: ['Mon'], count: 4, timezone: 'Asia/Taipei' }
  assertEquals(computeTemplateRuleUpdate(rule, 'set_absolute', {}), null)
})

Deno.test('computeTemplateRuleUpdate reapply_offset sets offset key', () => {
  const rule = { frequency: 'weekly', interval: 1, days: ['Mon'], count: 4, timezone: 'Asia/Taipei' }
  const result = computeTemplateRuleUpdate(rule, 'reapply_offset', { offset_minutes: 1440 })
  assertEquals(result, { frequency: 'weekly', interval: 1, days: ['Mon'], count: 4, timezone: 'Asia/Taipei', registration_deadline_offset_minutes: 1440 })
})

Deno.test('computeTemplateRuleUpdate reapply_offset same value returns null', () => {
  const rule = { frequency: 'weekly', interval: 1, days: ['Mon'], count: 4, timezone: 'Asia/Taipei', registration_deadline_offset_minutes: 1440 }
  assertEquals(computeTemplateRuleUpdate(rule, 'reapply_offset', { offset_minutes: 1440 }), null)
})

// diffEditableFields

Deno.test('diffEditableFields returns only differing fields', () => {
  const row = { title: 'Old', description: 'Same', max_capacity: 20 }
  const fields = { title: 'New', description: 'Same', max_capacity: 30 }
  const whitelist = new Set(['title', 'description', 'max_capacity'])
  const result = diffEditableFields(fields, row, whitelist)
  assertEquals(result, { title: 'New', max_capacity: 30 })
})

Deno.test('diffEditableFields skips unchanged fields', () => {
  const row = { title: 'Same', max_capacity: 20 }
  const fields = { title: 'Same', max_capacity: 20 }
  const whitelist = new Set(['title', 'max_capacity'])
  assertEquals(diffEditableFields(fields, row, whitelist), {})
})

Deno.test('diffEditableFields skips non-whitelist fields', () => {
  const row = { title: 'Old', source_url: 'https://x.com/old' }
  const fields = { title: 'New', source_url: 'https://x.com/new' }
  const whitelist = new Set(['title'])
  assertEquals(diffEditableFields(fields, row, whitelist), { title: 'New' })
})

// validateEditableFields

Deno.test('validateEditableFields rejects start_time', () => {
  assertEquals(validateEditableFields({ title: 'A', start_time: 'x' }), 'field "start_time" is not allowed in batch edits')
})

Deno.test('validateEditableFields rejects recurrence_rule', () => {
  assertEquals(validateEditableFields({ title: 'A', recurrence_rule: { frequency: 'weekly' } }), 'field "recurrence_rule" is not allowed in batch edits')
})

Deno.test('validateEditableFields rejects source_url', () => {
  assertEquals(validateEditableFields({ title: 'A', source_url: 'https://x.com/new' }), 'field "source_url" is not allowed in batch edits')
})

Deno.test('validateEditableFields rejects is_venue_hosted', () => {
  assertEquals(validateEditableFields({ title: 'A', is_venue_hosted: true }), 'field "is_venue_hosted" is not allowed in batch edits')
})

Deno.test('validateEditableFields accepts valid fields', () => {
  assertEquals(validateEditableFields({ title: 'A', description: 'B' }), null)
})

Deno.test('validateEditableFields accepts undefined fields', () => {
  assertEquals(validateEditableFields(undefined), null)
})

// Serialization boundary

Deno.test('BATCH_FIELDS_WHITELIST contains expected keys', () => {
  assertEquals(BATCH_FIELDS_WHITELIST.has('title'), true)
  assertEquals(BATCH_FIELDS_WHITELIST.has('source_url'), false)
  assertEquals(BATCH_FIELDS_WHITELIST.has('start_time'), false)
  assertEquals(BATCH_FIELDS_WHITELIST.has('recurrence_rule'), false)
  assertEquals(BATCH_FIELDS_WHITELIST.has('is_venue_hosted'), false)
})