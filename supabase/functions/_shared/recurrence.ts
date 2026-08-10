export type RecurrenceFrequency = 'weekly' | 'monthly'

export interface RecurrenceRule {
  frequency: RecurrenceFrequency
  interval: number
  days?: string[]
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

function copyTime(source: Date, target: Date): Date {
  target.setUTCHours(source.getUTCHours(), source.getUTCMinutes(), source.getUTCSeconds(), source.getUTCMilliseconds())
  return target
}

function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month + 1, 0)).getUTCDate()
}

export function validateRecurrenceRule(rule: RecurrenceRule): string | null {
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
  if (rule.until !== undefined && rule.until !== null && Number.isNaN(new Date(rule.until).getTime())) {
    return 'until must be a valid timestamp'
  }
  return null
}

export function generateRecurringDates(base: Date, rule: RecurrenceRule): Date[] {
  const count = rule.count ?? 4
  const dates: Date[] = []

  if (rule.frequency === 'weekly') {
    const selectedDays = (rule.days?.length ? rule.days : [DAY_NAMES[base.getUTCDay()]]).map((day) => DAY_MAP[day]).sort((a, b) => a - b)
    const baseWeekStart = new Date(Date.UTC(base.getUTCFullYear(), base.getUTCMonth(), base.getUTCDate() - base.getUTCDay()))

    for (let week = 0; dates.length < count - 1; week += rule.interval) {
      const weekStart = new Date(baseWeekStart)
      weekStart.setUTCDate(weekStart.getUTCDate() + week * 7)
      for (const day of selectedDays) {
        const candidate = new Date(weekStart)
        candidate.setUTCDate(candidate.getUTCDate() + day)
        copyTime(base, candidate)
        if (candidate > base) dates.push(candidate)
        if (dates.length === count - 1) break
      }
    }
  } else {
    const sourceDay = base.getUTCDate()
    for (let occurrence = 1; occurrence < count; occurrence += 1) {
      const month = base.getUTCMonth() + occurrence * rule.interval
      const year = base.getUTCFullYear() + Math.floor(month / 12)
      const normalizedMonth = ((month % 12) + 12) % 12
      const day = Math.min(sourceDay, daysInMonth(year, normalizedMonth))
      dates.push(copyTime(base, new Date(Date.UTC(year, normalizedMonth, day))))
    }
  }

  if (rule.until) {
    const until = new Date(rule.until)
    return dates.filter((date) => date <= until)
  }
  return dates
}
