import {
  DEFAULT_STALE_DAYS,
  MAX_STALE_DAYS,
  MIN_STALE_DAYS,
  parseStaleDays,
} from "./push-subscription-cleanup.ts";

Deno.test('parseStaleDays defaults to the documented threshold', () => {
  if (parseStaleDays(undefined) !== DEFAULT_STALE_DAYS) {
    throw new Error('expected default stale days')
  }
})

Deno.test('parseStaleDays accepts integers inside the bounded range', () => {
  if (parseStaleDays(MIN_STALE_DAYS) !== MIN_STALE_DAYS) throw new Error('lower bound rejected')
  if (parseStaleDays(MAX_STALE_DAYS) !== MAX_STALE_DAYS) throw new Error('upper bound rejected')
  if (parseStaleDays(180) !== 180) throw new Error('mid-range value rejected')
})

Deno.test('parseStaleDays rejects non-integers and out-of-range values', () => {
  const invalid: unknown[] = [
    null,
    '90',
    90.5,
    Number.NaN,
    MIN_STALE_DAYS - 1,
    MAX_STALE_DAYS + 1,
  ]
  for (const value of invalid) {
    try {
      parseStaleDays(value)
      throw new Error(`expected rejection for ${JSON.stringify(value) ?? String(value)}`)
    } catch (error) {
      if ((error as Error).message !== 'invalid_stale_days') throw error
    }
  }
})
