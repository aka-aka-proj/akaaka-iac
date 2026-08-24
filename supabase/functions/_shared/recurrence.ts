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
  timezone?: string
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

// Series cap (spec「前置條件」): total events including the original must not exceed 52.
export const MAX_SERIES_TOTAL = 52

// Callers must catch this and respond with 400 validation_error; an over-cap
// `until` series is rejected, never silently truncated (spec「前置條件」).
export class RecurrenceSeriesTooLongError extends Error {
  constructor() {
    super('recurrence series exceeds the maximum of 52 total events')
    this.name = 'RecurrenceSeriesTooLongError'
  }
}

// Legacy payloads (no `timezone`, required `count`, optional `until` alongside it)
// stay valid until the revised frontend ships to production — flip this off then
// (spec「部署相容期」, tracked in supabase/functions/DEPLOYMENT-NOTES.md).
const LEGACY_PAYLOAD_COMPAT_ENABLED = true

// Hard guards so generators always terminate even when callers bypass validation;
// validated input always terminates earlier via the count/until/series-cap checks.
const MAX_WEEK_STEPS = 5200
const MAX_MONTH_STEPS = 1200

interface CalendarDate {
  year: number
  month: number // 1-based
  day: number
}

interface WallTime {
  hour: number
  minute: number
  second: number
  millisecond: number
}

interface CalendarContext {
  baseMs: number
  baseDate: CalendarDate
  /** local weekday of the base date, Sun = 0 */
  baseWeekday: number
  timeOfDay: WallTime
  /** a candidate's local wall-clock date → UTC instant, preserving the base time-of-day */
  toInstant(date: CalendarDate): Date
}

function isValidTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone })
    return true
  } catch {
    return false
  }
}

function zonedPartsOf(instantMs: number, timeZone: string): { date: CalendarDate; time: WallTime; weekday: number } {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hour12: false,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    weekday: 'short',
  }).formatToParts(new Date(instantMs))
  const value = (type: string) => parts.find((part) => part.type === type)?.value ?? ''
  return {
    date: { year: Number(value('year')), month: Number(value('month')), day: Number(value('day')) },
    time: {
      hour: Number(value('hour')) % 24,
      minute: Number(value('minute')),
      second: Number(value('second')),
      millisecond: new Date(instantMs).getUTCMilliseconds(),
    },
    weekday: DAY_MAP[value('weekday')] ?? -1,
  }
}

function timeZoneOffsetMs(instantMs: number, timeZone: string): number {
  const { date, time } = zonedPartsOf(instantMs, timeZone)
  return Date.UTC(date.year, date.month - 1, date.day, time.hour, time.minute, time.second, time.millisecond) - instantMs
}

// Local wall-clock components in `timeZone` → UTC instant. Re-reading the offset
// at successive guesses makes DST transitions converge deterministically:
// ambiguous times resolve to the earlier instant, gap times shift forward.
function zonedWallTimeToUtcMs(date: CalendarDate, time: WallTime, timeZone: string): number {
  const naive = Date.UTC(date.year, date.month - 1, date.day, time.hour, time.minute, time.second, time.millisecond)
  let utc = naive
  for (let i = 0; i < 3; i += 1) {
    const next = naive - timeZoneOffsetMs(utc, timeZone)
    if (next === utc) break
    utc = next
  }
  return utc
}

function addCalendarDays(date: CalendarDate, days: number): CalendarDate {
  const shifted = new Date(Date.UTC(date.year, date.month - 1, date.day + days))
  return { year: shifted.getUTCFullYear(), month: shifted.getUTCMonth() + 1, day: shifted.getUTCDate() }
}

function weekdayOf(date: CalendarDate): number {
  return new Date(Date.UTC(date.year, date.month - 1, date.day)).getUTCDay()
}

function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate()
}

function nthWeekdayOfMonth(year: number, month: number, weekday: number, ordinal: number): CalendarDate {
  if (ordinal === 5) {
    const lastDay = daysInMonth(year, month)
    const shift = (weekdayOf({ year, month, day: lastDay }) - weekday + 7) % 7
    return { year, month, day: lastDay - shift }
  }
  const offset = (weekday - weekdayOf({ year, month, day: 1 }) + 7) % 7
  return { year, month, day: 1 + offset + (ordinal - 1) * 7 }
}

export type UnvalidatedRecurrenceRule = Omit<RecurrenceRule, 'monthly_by'> & { monthly_by?: string; timezone?: unknown }

function modeAllowedFields(rule: UnvalidatedRecurrenceRule): Set<string> {
  if (rule.frequency === 'weekly') {
    return new Set(['frequency', 'interval', 'days', 'count', 'until', 'timezone'])
  }
  if (rule.monthly_by === 'weekday') {
    return new Set(['frequency', 'interval', 'monthly_by', 'week_ordinal', 'days', 'count', 'until', 'timezone'])
  }
  return new Set(['frequency', 'interval', 'monthly_by', 'count', 'until', 'timezone'])
}

export function validateRecurrenceRule(rule: UnvalidatedRecurrenceRule): string | null {
  if (!rule || (rule.frequency !== 'weekly' && rule.frequency !== 'monthly')) {
    return 'frequency must be "weekly" or "monthly"'
  }
  if (!Number.isInteger(rule.interval) || rule.interval < 1 || rule.interval > 52) {
    return 'interval must be an integer between 1 and 52'
  }

  const hasUntil = rule.until !== undefined && rule.until !== null
  if (
    rule.count !== undefined &&
    (!Number.isInteger(rule.count) || rule.count < 1 || rule.count > 52)
  ) {
    return 'count must be an integer between 1 and 52'
  }
  if (rule.days !== undefined) {
    if (!Array.isArray(rule.days) || rule.days.some((day) => !DAY_NAMES.includes(day)) || new Set(rule.days).size !== rule.days.length) {
      return 'days must contain unique values from Sun through Sat'
    }
  }
  if (hasUntil && (typeof rule.until !== 'string' || Number.isNaN(new Date(rule.until).getTime()))) {
    return 'until must be a valid timestamp'
  }

  const newStylePayload = rule.timezone !== undefined && rule.timezone !== null
  if (newStylePayload || !LEGACY_PAYLOAD_COMPAT_ENABLED) {
    if (typeof rule.timezone !== 'string' || !isValidTimeZone(rule.timezone)) {
      return 'timezone must be a valid IANA time zone name'
    }
    if ((rule.count !== undefined) === hasUntil) {
      return 'provide either count or until, not both'
    }
    for (const key of Object.keys(rule)) {
      if (!modeAllowedFields(rule).has(key)) {
        return `field "${key}" is not allowed for ${rule.frequency} recurrence`
      }
    }
  } else if (rule.count === undefined) {
    // Legacy contract: count is required, until optional alongside it.
    return 'count must be an integer between 1 and 52'
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

function createCalendarContext(base: Date, rule: RecurrenceRule): CalendarContext {
  if (rule.timezone !== undefined && rule.timezone !== null) {
    if (typeof rule.timezone !== 'string' || !isValidTimeZone(rule.timezone)) {
      throw new Error(`invalid recurrence rule timezone: ${String(rule.timezone)}`)
    }
    const parts = zonedPartsOf(base.getTime(), rule.timezone)
    return {
      baseMs: base.getTime(),
      baseDate: parts.date,
      baseWeekday: parts.weekday,
      timeOfDay: parts.time,
      toInstant: (date) => new Date(zonedWallTimeToUtcMs(date, parts.time, rule.timezone as string)),
    }
  }
  return {
    baseMs: base.getTime(),
    baseDate: { year: base.getUTCFullYear(), month: base.getUTCMonth() + 1, day: base.getUTCDate() },
    baseWeekday: base.getUTCDay(),
    timeOfDay: {
      hour: base.getUTCHours(),
      minute: base.getUTCMinutes(),
      second: base.getUTCSeconds(),
      millisecond: base.getUTCMilliseconds(),
    },
    toInstant: (date) =>
      new Date(
        Date.UTC(
          date.year,
          date.month - 1,
          date.day,
          base.getUTCHours(),
          base.getUTCMinutes(),
          base.getUTCSeconds(),
          base.getUTCMilliseconds(),
        ),
      ),
  }
}

function selectWeekdays(rule: RecurrenceRule, context: CalendarContext): number[] {
  const chosen = rule.days?.length ? [...new Set(rule.days)].map((day) => DAY_MAP[day]) : [context.baseWeekday]
  return [...new Set(chosen)].sort((a, b) => a - b)
}

// Each selected weekday's occurrences live in the week starting on the base
// date's Sunday; stepping whole weeks by `interval` equals "first occurrence
// after the base, then every `interval` weeks" for every selected weekday.
function* weeklyCandidates(context: CalendarContext, interval: number, selectedDays: number[]): Generator<Date> {
  const sundayStart = addCalendarDays(context.baseDate, -context.baseWeekday)
  for (let week = 0, step = 0; step < MAX_WEEK_STEPS; week += interval, step += 1) {
    const weekStart = addCalendarDays(sundayStart, week * 7)
    for (const day of selectedDays) {
      const instant = context.toInstant(addCalendarDays(weekStart, day))
      if (instant.getTime() > context.baseMs) yield instant
    }
  }
}

function monthAfter(context: CalendarContext, occurrence: number): CalendarDate {
  const totalMonths = context.baseDate.month - 1 + occurrence
  const year = context.baseDate.year + Math.floor(totalMonths / 12)
  return { year, month: ((totalMonths % 12) + 12) % 12 + 1, day: 1 }
}

function* monthlyByDateCandidates(context: CalendarContext, interval: number): Generator<Date> {
  const sourceDay = context.baseDate.day
  for (let occurrence = 1, step = 0; step < MAX_MONTH_STEPS; occurrence += interval, step += 1) {
    const month = monthAfter(context, occurrence)
    const day = Math.min(sourceDay, daysInMonth(month.year, month.month))
    yield context.toInstant({ ...month, day })
  }
}

function* monthlyByWeekdayCandidates(
  context: CalendarContext,
  interval: number,
  selectedDays: number[],
  ordinal: number,
): Generator<Date> {
  for (let occurrence = 0, step = 0; step < MAX_MONTH_STEPS; occurrence += interval, step += 1) {
    const month = monthAfter(context, occurrence)
    const dates = selectedDays
      .map((weekday) => context.toInstant(nthWeekdayOfMonth(month.year, month.month, weekday, ordinal)))
      .filter((candidate) => candidate.getTime() > context.baseMs)
      .sort((a, b) => a.getTime() - b.getTime())
    for (const candidate of dates) yield candidate
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

  const context = createCalendarContext(base, rule)
  const selectedDays = selectWeekdays(rule, context)
  const candidates =
    rule.frequency === 'weekly'
      ? weeklyCandidates(context, rule.interval, selectedDays)
      : rule.monthly_by === 'weekday'
        ? monthlyByWeekdayCandidates(context, rule.interval, selectedDays, rule.week_ordinal as number)
        : monthlyByDateCandidates(context, rule.interval)

  for (const candidate of candidates) {
    if (candidate.getTime() <= base.getTime()) continue
    if (until !== null && candidate.getTime() > until.getTime()) break
    const key = candidate.toISOString()
    if (seen.has(key)) continue
    seen.add(key)
    if (dates.length >= limit) {
      if (rule.count !== undefined) break
      throw new RecurrenceSeriesTooLongError()
    }
    dates.push(candidate)
  }
  return dates.sort((a, b) => a.getTime() - b.getTime())
}
