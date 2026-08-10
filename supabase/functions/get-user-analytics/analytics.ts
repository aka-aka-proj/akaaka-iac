export function calculateApprovalRate(
  approved: number,
  rejected: number,
  pending: number,
): number {
  const denominator = approved + rejected + pending;
  return denominator > 0 ? Math.round((approved / denominator) * 100) : 0;
}

export function calculateAttendanceRate(
  checkedIn: number,
  approved: number,
): number {
  return approved > 0 ? Math.round((checkedIn / approved) * 100) : 0;
}

export function collectTags(eventTypes: (string | null)[]): string[] {
  const tags = new Set<string>();
  for (const eventType of eventTypes) {
    if (!eventType) continue;
    for (const tag of eventType.split(",")) {
      const trimmed = tag.trim();
      if (trimmed) tags.add(trimmed);
    }
  }
  return [...tags];
}
