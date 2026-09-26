const source = await Deno.readTextFile(new URL('../testing/authenticated-test-agent.ts', import.meta.url))

Deno.test('hosted blocklist scenario covers status and acknowledgement scope matrix', () => {
  for (const marker of [
    'blocklist-acknowledgement-event-scoped',
    'blocklist-status-pending-conflict',
    'blocklist-status-approved-conflict',
    'blocklist-status-waitlisted-conflict',
    'blocklist-status-cancellation_pending-conflict',
    'blocklist-status-cancellation_rejected-conflict',
    'blocklist-status-rejected-ignored',
    'blocklist-status-cancelled-ignored',
  ]) {
    if (!source.includes(marker)) throw new Error(`missing hosted evidence marker: ${marker}`)
  }
})

Deno.test('hosted recurrence scenario covers issue 103 staging behavior matrix', () => {
  for (const marker of [
    'recurrence-offset-instance-deadline',
    'recurrence-legacy-absolute-deadline',
    'recurrence-scheduling-lock-rejected',
  ]) {
    if (!source.includes(marker)) throw new Error(`missing hosted recurrence evidence marker: ${marker}`)
  }
})

Deno.test('hosted blocklist series scenario covers atomic conflict and stale snapshot', () => {
  for (const marker of [
    'blocklist-series-conflict-all-or-nothing',
    'blocklist-series-stale-snapshot-fail-closed',
  ]) {
    if (!source.includes(marker)) throw new Error(`missing hosted blocklist series evidence marker: ${marker}`)
  }
})
