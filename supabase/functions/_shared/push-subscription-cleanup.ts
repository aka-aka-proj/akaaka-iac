export const DEFAULT_STALE_DAYS = 90;
export const MIN_STALE_DAYS = 30;
export const MAX_STALE_DAYS = 730;

export interface CleanupSummary {
  deleted: number;
  stale_days: number;
}

export function parseStaleDays(value: unknown): number {
  if (value === undefined) return DEFAULT_STALE_DAYS;
  if (
    typeof value !== "number" || !Number.isInteger(value) ||
    value < MIN_STALE_DAYS || value > MAX_STALE_DAYS
  ) {
    throw new Error("invalid_stale_days");
  }
  return value;
}
