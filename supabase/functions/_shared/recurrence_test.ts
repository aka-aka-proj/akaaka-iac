import { generateRecurringDates, validateRecurrenceRule, RecurrenceSeriesTooLongError } from './recurrence.ts'
import type { RecurrenceRule, UnvalidatedRecurrenceRule } from './recurrence.ts'

function assertEquals<T>(actual: T, expected: T): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
  }
}

const base = new Date('2026-08-10T12:00:00.000Z') // Monday

Deno.test('weekly recurrence uses selected days and interval without duplicates', () => {
  const dates = generateRecurringDates(base, { frequency: 'weekly', interval: 1, days: ['Mon', 'Wed'], count: 5 })
  assertEquals(dates.map((date) => date.toISOString()), [
    '2026-08-12T12:00:00.000Z',
    '2026-08-17T12:00:00.000Z',
    '2026-08-19T12:00:00.000Z',
    '2026-08-24T12:00:00.000Z',
  ])
})

Deno.test('weekly recurrence defaults to the base event weekday', () => {
  const dates = generateRecurringDates(base, { frequency: 'weekly', interval: 1, days: [], count: 3 })
  assertEquals(dates.map((date) => date.toISOString()), [
    '2026-08-17T12:00:00.000Z',
    '2026-08-24T12:00:00.000Z',
  ])
})

Deno.test('monthly recurrence clamps dates to the end of short months', () => {
  const dates = generateRecurringDates(new Date('2026-01-31T12:00:00.000Z'), { frequency: 'monthly', interval: 1, count: 4 })
  assertEquals(dates.map((date) => date.toISOString()), [
    '2026-02-28T12:00:00.000Z',
    '2026-03-31T12:00:00.000Z',
    '2026-04-30T12:00:00.000Z',
  ])
})

Deno.test('validation rejects invalid recurrence rules', () => {
  assertEquals(validateRecurrenceRule({ frequency: 'weekly', interval: 0 }), 'interval must be an integer between 1 and 52')
  assertEquals(validateRecurrenceRule({ frequency: 'weekly', interval: 1, days: ['Mon', 'Mon'] }), 'days must contain unique values from Sun through Sat')
})

// Shared canonical test vectors — must stay in sync with akaaka-frontend src/lib/recurrence tests.

const v1BaseSunday = new Date('2026-03-15T14:00:00.000Z')
Deno.test('V1 weekly recurrence with multi-day selection and interval 2', () => {
  const dates = generateRecurringDates(v1BaseSunday, { frequency: 'weekly', interval: 2, days: ['Mon', 'Wed'], count: 5 })
  assertEquals(dates.map((date) => date.toISOString()), [
    '2026-03-16T14:00:00.000Z',
    '2026-03-18T14:00:00.000Z',
    '2026-03-30T14:00:00.000Z',
    '2026-04-01T14:00:00.000Z',
  ])
})

Deno.test('V2 weekly recurrence defaults to base weekday when days omitted or empty', () => {
  const omitted = generateRecurringDates(v1BaseSunday, { frequency: 'weekly', interval: 1, count: 3 })
  const empty = generateRecurringDates(v1BaseSunday, { frequency: 'weekly', interval: 1, days: [], count: 3 })
  assertEquals(empty.map((date) => date.toISOString()), ['2026-03-22T14:00:00.000Z', '2026-03-29T14:00:00.000Z'])
  assertEquals(omitted.map((date) => date.toISOString()), empty.map((date) => date.toISOString()))
})

Deno.test('V3 monthly by-date clamps to end of short months', () => {
  const dates = generateRecurringDates(new Date('2026-01-31T09:00:00.000Z'), { frequency: 'monthly', interval: 1, count: 4 })
  assertEquals(dates.map((date) => date.toISOString()), [
    '2026-02-28T09:00:00.000Z',
    '2026-03-31T09:00:00.000Z',
    '2026-04-30T09:00:00.000Z',
  ])
})

Deno.test('V4 monthly weekday mode takes the Nth occurrence of the selected weekday', () => {
  const dates = generateRecurringDates(v1BaseSunday, {
    frequency: 'monthly',
    monthly_by: 'weekday',
    week_ordinal: 3,
    days: ['Wed'],
    interval: 1,
    count: 4,
  })
  assertEquals(dates.map((date) => date.toISOString()), [
    '2026-03-18T14:00:00.000Z',
    '2026-04-15T14:00:00.000Z',
    '2026-05-20T14:00:00.000Z',
  ])
})

Deno.test('V5 monthly weekday mode treats ordinal 5 as the last occurrence', () => {
  const dates = generateRecurringDates(v1BaseSunday, {
    frequency: 'monthly',
    monthly_by: 'weekday',
    week_ordinal: 5,
    days: ['Fri'],
    interval: 1,
    count: 3,
  })
  assertEquals(dates.map((date) => date.toISOString()), [
    '2026-03-27T14:00:00.000Z',
    '2026-04-24T14:00:00.000Z',
  ])
})

Deno.test('V6 until keeps candidates on or before the cutoff', () => {
  const dates = generateRecurringDates(new Date('2026-03-15T10:00:00.000Z'), {
    frequency: 'weekly',
    interval: 1,
    until: '2026-03-22T10:00:00.000Z',
  })
  assertEquals(dates.map((date) => date.toISOString()), ['2026-03-22T10:00:00.000Z'])
})

Deno.test('V7 count and until are mutually exclusive and at least one is required', () => {
  assertEquals(
    validateRecurrenceRule({ frequency: 'weekly', interval: 1, count: 4, until: '2026-04-15T00:00:00.000Z', timezone: 'UTC' }),
    'provide either count or until, not both',
  )
  assertEquals(
    validateRecurrenceRule({ frequency: 'weekly', interval: 1, timezone: 'UTC' }),
    'provide either count or until, not both',
  )
})

Deno.test('V8 monthly weekday skips a candidate identical to the base event', () => {
  const dates = generateRecurringDates(new Date('2026-03-18T14:00:00.000Z'), {
    frequency: 'monthly',
    monthly_by: 'weekday',
    week_ordinal: 3,
    days: ['Wed'],
    interval: 1,
    count: 2,
  })
  assertEquals(dates.map((date) => date.toISOString()), ['2026-04-15T14:00:00.000Z'])
})

Deno.test('V9 validation rejects invalid monthly weekday rules', () => {
  assertEquals(
    validateRecurrenceRule({ frequency: 'monthly', monthly_by: 'weekday', days: ['Wed'], interval: 1, count: 2 }),
    'week_ordinal must be an integer between 1 and 5',
  )
  assertEquals(
    validateRecurrenceRule({ frequency: 'monthly', monthly_by: 'weekday', week_ordinal: 6, days: ['Wed'], interval: 1, count: 2 }),
    'week_ordinal must be an integer between 1 and 5',
  )
  assertEquals(
    validateRecurrenceRule({ frequency: 'monthly', monthly_by: 'weekday', week_ordinal: 2, interval: 1, count: 2 }),
    'days must contain at least one weekday when monthly_by is "weekday"',
  )
  assertEquals(
    validateRecurrenceRule({ frequency: 'monthly', monthly_by: 'date', week_ordinal: 2, interval: 1, count: 2 }),
    'week_ordinal is only allowed when monthly_by is "weekday"',
  )
  assertEquals(
    validateRecurrenceRule({ frequency: 'weekly', monthly_by: 'weekday', week_ordinal: 2, days: ['Mon'], interval: 1, count: 2 }),
    'monthly_by and week_ordinal are only allowed for monthly frequency',
  )
  assertEquals(
    validateRecurrenceRule({ frequency: 'monthly', monthly_by: 'yearly', interval: 1, count: 2 }),
    'monthly_by must be "date" or "weekday"',
  )
})

Deno.test('V10 monthly weekday sorts same-month candidates chronologically', () => {
  const dates = generateRecurringDates(new Date('2026-02-01T08:00:00.000Z'), {
    frequency: 'monthly',
    monthly_by: 'weekday',
    week_ordinal: 5,
    days: ['Sat', 'Sun'],
    interval: 1,
    count: 4,
  })
  assertEquals(dates.map((date) => date.toISOString()), [
    '2026-02-22T08:00:00.000Z',
    '2026-02-28T08:00:00.000Z',
    '2026-03-28T08:00:00.000Z',
  ])
})

Deno.test('V11 count = 1 generates no follow-up copies', () => {
  const weekly = generateRecurringDates(v1BaseSunday, { frequency: 'weekly', interval: 2, days: ['Mon'], count: 1 })
  const monthly = generateRecurringDates(new Date('2026-01-31T09:00:00.000Z'), { frequency: 'monthly', interval: 1, count: 1 })
  assertEquals(weekly.map((date) => date.toISOString()), [])
  assertEquals(monthly.map((date) => date.toISOString()), [])
})

function ruleWithUntil(until: unknown): UnvalidatedRecurrenceRule {
  return { frequency: 'weekly', interval: 1, until } as unknown as UnvalidatedRecurrenceRule
}

Deno.test('V12 validation rejects non-string or empty until values', () => {
  for (const until of [0, false, '', 123]) {
    assertEquals(validateRecurrenceRule(ruleWithUntil(until)), 'until must be a valid timestamp')
  }
})

Deno.test('V12b generation applies a non-string until as a real cutoff instead of ignoring it', () => {
  const dates = generateRecurringDates(v1BaseSunday, { frequency: 'weekly', interval: 1, until: 0 } as unknown as RecurrenceRule)
  assertEquals(dates.map((date) => date.toISOString()), [])
})

Deno.test('V13 until series exceeding 52 total events is rejected, not truncated', () => {
  let thrown: unknown
  try {
    generateRecurringDates(new Date('2026-08-10T12:00:00.000Z'), {
      frequency: 'weekly',
      interval: 1,
      until: '2030-01-01T12:00:00.000Z',
    })
  } catch (err) {
    thrown = err
  }
  assertEquals(thrown instanceof RecurrenceSeriesTooLongError, true)
})

Deno.test('V14 until series of exactly 52 total events succeeds', () => {
  const dates = generateRecurringDates(new Date('2026-08-10T12:00:00.000Z'), {
    frequency: 'weekly',
    interval: 1,
    until: '2027-08-02T12:00:00.000Z',
  })
  assertEquals(dates.length, 51)
})

Deno.test('V15 weekly weekdays are resolved in the rule timezone, not UTC', () => {
  const base = new Date('2026-08-10T17:30:00.000Z') // Mon 16:30Z = Tue 01:30 Asia/Taipei
  const tuesdays = generateRecurringDates(base, { frequency: 'weekly', interval: 1, days: ['Tue'], count: 4, timezone: 'Asia/Taipei' })
  assertEquals(tuesdays.map((date) => date.toISOString()), [
    '2026-08-17T17:30:00.000Z',
    '2026-08-24T17:30:00.000Z',
    '2026-08-31T17:30:00.000Z',
  ])
  const mondays = generateRecurringDates(base, { frequency: 'weekly', interval: 1, days: ['Mon'], count: 3, timezone: 'Asia/Taipei' })
  assertEquals(mondays.map((date) => date.toISOString()), [
    '2026-08-16T17:30:00.000Z',
    '2026-08-23T17:30:00.000Z',
  ])
})

Deno.test('V16 monthly by-date clamps to the end of short months in the rule timezone', () => {
  const dates = generateRecurringDates(new Date('2026-01-31T04:00:00.000Z'), {
    frequency: 'monthly',
    interval: 1,
    count: 4,
    timezone: 'Asia/Taipei',
  })
  assertEquals(dates.map((date) => date.toISOString()), [
    '2026-02-28T04:00:00.000Z',
    '2026-03-31T04:00:00.000Z',
    '2026-04-30T04:00:00.000Z',
  ])
})

Deno.test('V17 monthly nth-weekday candidates strictly after the base instant across time zones', () => {
  const dates = generateRecurringDates(new Date('2026-03-15T16:30:00.000Z'), {
    frequency: 'monthly',
    monthly_by: 'weekday',
    week_ordinal: 3,
    days: ['Mon'],
    interval: 1,
    count: 4,
    timezone: 'Asia/Taipei',
  })
  assertEquals(dates.map((date) => date.toISOString()), [
    '2026-04-19T16:30:00.000Z',
    '2026-05-17T16:30:00.000Z',
    '2026-06-14T16:30:00.000Z',
  ])
})

function ruleWithExtraFields(fields: Record<string, unknown>): UnvalidatedRecurrenceRule {
  return { ...fields } as unknown as UnvalidatedRecurrenceRule
}

Deno.test('V18 new-style rules reject fields outside their mode whitelist', () => {
  assertEquals(
    validateRecurrenceRule(ruleWithExtraFields({
      frequency: 'weekly', interval: 1, monthly_by: 'weekday', week_ordinal: 2, days: ['Mon'], count: 2, timezone: 'UTC',
    })),
    'field "monthly_by" is not allowed for weekly recurrence',
  )
  assertEquals(
    validateRecurrenceRule(ruleWithExtraFields({
      frequency: 'monthly', monthly_by: 'date', interval: 1, days: ['Mon'], count: 2, timezone: 'UTC',
    })),
    'field "days" is not allowed for monthly recurrence',
  )
  assertEquals(
    validateRecurrenceRule(ruleWithExtraFields({
      frequency: 'weekly', intervl: 3, interval: 1, count: 2, timezone: 'UTC',
    })),
    'field "intervl" is not allowed for weekly recurrence',
  )
})

Deno.test('V19 timezone must be a valid IANA name on new-style payloads; legacy payloads stay valid', () => {
  assertEquals(
    validateRecurrenceRule({ frequency: 'weekly', interval: 1, count: 2, timezone: 'Mars/Olympus' }),
    'timezone must be a valid IANA time zone name',
  )
  assertEquals(
    validateRecurrenceRule(ruleWithExtraFields({ frequency: 'weekly', interval: 1, count: 2, timezone: 123 })),
    'timezone must be a valid IANA time zone name',
  )
  assertEquals(
    validateRecurrenceRule({ frequency: 'weekly', interval: 1, count: 4, until: '2026-09-30T00:00:00.000Z' }),
    null,
  )
})

Deno.test('V21 monthly by-date steps by interval months from the base event', () => {
  const dates = generateRecurringDates(new Date('2026-03-15T09:00:00.000Z'), { frequency: 'monthly', interval: 2, count: 4 })
  assertEquals(dates.map((date) => date.toISOString()), [
    '2026-05-15T09:00:00.000Z',
    '2026-07-15T09:00:00.000Z',
    '2026-09-15T09:00:00.000Z',
  ])
})

Deno.test('V20 legacy count and until coexist: filter by until first, then truncate by count', () => {
  const base = new Date('2026-08-10T12:00:00.000Z')
  const boundedByUntil = generateRecurringDates(base, {
    frequency: 'weekly', interval: 1, count: 4, until: '2026-08-24T12:00:00.000Z',
  })
  assertEquals(boundedByUntil.map((date) => date.toISOString()), [
    '2026-08-17T12:00:00.000Z',
    '2026-08-24T12:00:00.000Z',
  ])
  const truncatedByCount = generateRecurringDates(base, {
    frequency: 'weekly', interval: 1, count: 2, until: '2027-01-01T00:00:00.000Z',
  })
  assertEquals(truncatedByCount.map((date) => date.toISOString()), [
    '2026-08-17T12:00:00.000Z',
  ])
})
