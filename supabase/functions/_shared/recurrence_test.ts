import { generateRecurringDates, validateRecurrenceRule } from './recurrence.ts'

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
