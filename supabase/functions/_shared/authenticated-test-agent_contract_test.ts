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
