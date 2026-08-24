export type RecurrenceFrequency = 'weekly' | 'monthly'

export type MonthlyBy = 'date' | 'weekday'

export interface RecurrenceRule {
  frequency: RecurrenceFrequency
  interval: number
  days?: string[]
  monthly_by?: MonthlyBy
  week_ordinal?: number
  count?: number
  until?: string
}

const DAY_MAP: Record<string, number> = {
  Sun: 0,
  Mon: 1,
  Tue: 2,
  Wed: 3,
  Thu: 4,
  Fri: 5,
  Sat: 6,
}

const DAY_NAMES = Object.keys(DAY_MAP)

export const MAX_SERIES_TOTAL = 52

// Callers must catch this and respond with 400 validation_error; an over-cap
// `until` series is rejected, never silently truncated (spec「前置條件」).
export class RecurrenceSeriesTooLongError extends Error {
  constructor() {
    super('recurrence series exceeds the maximum of 52 total events')
    this.name = 'RecurrenceSeriesTooLongError'
  }
}

// Hard guards so generators always terminate even when callers bypass validation;
// validated input always terminates earlier via the count/until/series-cap checks.
const MAX_WEEK_STEPS = 5200
const MAX_MONTH_STEPS = 1200

function copyTime(source: Date, target: Date): Date {
  target.setUTCHours(source.getUTCHours(), source.getUTCMinutes(), source.getUTCSeconds(), source.getUTCMilliseconds())
  return target
}

function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month + 1, 0)).getUTCDate()
}

function nthWeekdayOfMonth(year: number, month: number, weekday: number, ordinal: number): Date {
  if (ordinal === 5) {
    const lastDay = daysInMonth(year, month)
    const lastDate = new Date(Date.UTC(year, month, lastDay))
    const shift = (lastDate.getUTCDay() - weekday + 7) % 7
    return new Date(Date.UTC(year, month, lastDay - shift))
  }
  const first = new Date(Date.UTC(year, month, 1))
  const offset = (weekday - first.getUTCDay() + 7) % 7
  return new Date(Date.UTC(year, month, 1 + offset + (ordinal - 1) * 7))
}

export type UnvalidatedRecurrenceRule = Omit<RecurrenceRule, 'monthly_by'> & { monthly_by?: string }

export function validateRecurrenceRule(rule: UnvalidatedRecurrenceRule): string | null {
  if (!rule || (rule.frequency !== 'weekly' && rule.frequency !== 'monthly')) {
    return 'frequency must be "weekly" or "monthly"'
  }
  if (!Number.isInteger(rule.interval) || rule.interval < 1 || rule.interval > 52) {
    return 'interval must be an integer between 1 and 52'
  }
  if (rule.count !== undefined && (!Number.isInteger(rule.count) || rule.count < 1 || rule.count > 52)) {
    return 'count must be an integer between 1 and 52'
  }
  if (rule.days !== undefined) {
    if (!Array.isArray(rule.days) || rule.days.some((day) => !DAY_NAMES.includes(day)) || new Set(rule.days).size !== rule.days.length) {
      return 'days must contain unique values from Sun through Sat'
    }
  }
  if (rule.until !== undefined && rule.until !== null && (typeof rule.until !== 'string' || Number.isNaN(new Date(rule.until).getTime()))) {
    return 'until must be a valid timestamp'
  }
  if ((rule.count !== undefined) === (rule.until !== undefined && rule.until !== null)) {
    return 'provide either count or until, not both'
  }
  if (rule.week_ordinal !== undefined && !(rule.frequency === 'monthly' && rule.monthly_by === 'weekday')) {
    return rule.frequency === 'monthly'
      ? 'week_ordinal is only allowed when monthly_by is "weekday"'
      : 'monthly_by and week_ordinal are only allowed for monthly frequency'
  }
  if (rule.monthly_by !== undefined) {
    if (rule.frequency !== 'monthly') {
      return 'monthly_by and week_ordinal are only allowed for monthly frequency'
    }
    if (rule.monthly_by !== 'date' && rule.monthly_by !== 'weekday') {
      return 'monthly_by must be "date" or "weekday"'
    }
    if (rule.monthly_by === 'weekday') {
      if (!Array.isArray(rule.days) || rule.days.length === 0) {
        return 'days must contain at least one weekday when monthly_by is "weekday"'
      }
      if (!Number.isInteger(rule.week_ordinal) || (rule.week_ordinal as number) < 1 || (rule.week_ordinal as number) > 5) {
        return 'week_ordinal must be an integer between 1 and 5'
      }
    }
  }
  return null
}

function* weeklyCandidates(base: Date, rule: RecurrenceRule): Generator<Date> {
  const selectedDays = (rule.days?.length ? rule.days : [DAY_NAMES[base.getUTCDay()]])
    .map((day) => DAY_MAP[day])
    .sort((a, b) => a - b)
  const baseWeekStart = new Date(Date.UTC(base.getUTCFullYear(), base.getUTCMonth(), base.getUTCDate() - base.getUTCDay()))

  for (let week = 0, step = 0; step < MAX_WEEK_STEPS; week += rule.interval, step += 1) {
    const weekStart = new Date(baseWeekStart)
    weekStart.setUTCDate(weekStart.getUTCDate() + week * 7)
    for (const day of selectedDays) {
      const candidate = new Date(weekStart)
      candidate.setUTCDate(candidate.getUTCDate() + day)
      copyTime(base, candidate)
      if (candidate > base) yield candidate
    }
  }
}

function* monthlyCandidates(base: Date, rule: RecurrenceRule): Generator<Date> {
  if (rule.monthly_by === 'weekday') {
    const selectedDays = [...new Set((rule.days ?? []).map((day) => DAY_MAP[day]))].sort((a, b) => a - b)
    const ordinal = rule.week_ordinal as number
    for (let occurrence = 0, step = 0; step < MAX_MONTH_STEPS; occurrence += rule.interval, step += 1) {
      const month = base.getUTCMonth() + occurrence
      const year = base.getUTCFullYear() + Math.floor(month / 12)
      const normalizedMonth = ((month % 12) + 12) % 12
      const monthDates = selectedDays
        .map((weekday) => copyTime(base, nthWeekdayOfMonth(year, normalizedMonth, weekday, ordinal)))
        .filter((candidate) => candidate > base)
        .sort((a, b) => a.getTime() - b.getTime())
      for (const candidate of monthDates) yield candidate
    }
    return
  }

  const sourceDay = base.getUTCDate()
  for (let occurrence = 1, step = 0; step < MAX_MONTH_STEPS; occurrence += rule.interval, step += 1) {
    const month = base.getUTCMonth() + occurrence
    const year = base.getUTCFullYear() + Math.floor(month / 12)
    const normalizedMonth = ((month % 12) + 12) % 12
    const day = Math.min(sourceDay, daysInMonth(year, normalizedMonth))
    yield copyTime(base, new Date(Date.UTC(year, normalizedMonth, day)))
  }
}

/**
 * Canonical date algorithm shared with the frontend preview (spec:
 * docs/spec/features/events/007-recurring-events-spec.md「日期演算法」).
 * Candidates are enumerated in chronological order, filtered to strictly-after-base,
 * cut by `until` (inclusive) or truncated to `count - 1`, deduplicated, ascending.
 * Throws RecurrenceSeriesTooLongError when an `until` rule would exceed MAX_SERIES_TOTAL.
 */
export function generateRecurringDates(base: Date, rule: RecurrenceRule): Date[] {
  // count includes the original event; the until path shares the same series cap.
  const limit = Math.min(rule.count ?? MAX_SERIES_TOTAL, MAX_SERIES_TOTAL) - 1
  if (limit <= 0) return []
  // Not a truthiness check — falsy values like 0 must not disable the cutoff.
  const until = rule.until != null ? new Date(rule.until) : null
  const seen = new Set<string>()
  const dates: Date[] = []

  const candidates = rule.frequency === 'weekly' ? weeklyCandidates(base, rule) : monthlyCandidates(base, rule)
  for (const candidate of candidates) {
    if (candidate <= base) continue
    if (until !== null && candidate > until) break
    const key = candidate.toISOString()
    if (seen.has(key)) continue
    seen.add(key)
    if (dates.length >= limit) {
      if (rule.count !== undefined) break
      throw new RecurrenceSeriesTooLongError()
    }
    dates.push(candidate)
  }
  return dates
}
