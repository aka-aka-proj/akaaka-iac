export function parseBlocklistAcknowledgment(value: unknown): boolean | null {
  return value === undefined ? false : typeof value === 'boolean' ? value : null
}

export function blocklistConflictResponse(
  error: { message?: string; details?: string } | null,
  authorizedEvents: ReadonlyArray<{ id: string; creator_id: string }> = [],
) {
  if (error?.message !== 'blocklist_confirmation_required') return null
  const event = authorizedEvents.find((item) => item.id === error.details)
  if (authorizedEvents.length > 0 && !event) return null
  return {
    error: {
      code: 'blocklist_confirmation_required',
      message: 'Confirmation is required before continuing.',
      details: event ? { warning_event_id: event.id, host_profile_id: event.creator_id } : {},
    },
  }
}
