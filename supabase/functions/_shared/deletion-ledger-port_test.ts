import {
  createInMemoryDeletionLedger,
} from './deletion-ledger-port.ts'

const event = {
  subject: 'subject-hash-1',
  deletionEpoch: 7,
  kind: 'account' as const,
  deviceIds: ['device-1'],
  providerKeyIds: ['provider-key-1'],
  idempotencyKey: 'account-delete-7',
  createdAt: '2026-08-16T00:00:00Z',
  auditActor: 'synthetic-test',
}

Deno.test('provider-neutral ledger port appends idempotently and scopes restore reads', async () => {
  const ledger = createInMemoryDeletionLedger()
  const first = await ledger.append(event)
  const duplicate = await ledger.append(event)
  if (first.status !== 'recorded' || duplicate.status !== 'recorded') throw new Error('unexpected append status')
  if (duplicate.idempotencyKey !== first.idempotencyKey) throw new Error('duplicate append changed identity')

  const own = await ledger.listForRestore(event.subject)
  const other = await ledger.listForRestore('subject-hash-2')
  if (own.length !== 1 || other.length !== 0) throw new Error('restore read was not scoped')
})

Deno.test('ledger status transitions are monotonic and preserve failure state', async () => {
  const ledger = createInMemoryDeletionLedger()
  await ledger.append(event)
  const applied = await ledger.transition({
    subject: event.subject,
    idempotencyKey: event.idempotencyKey,
    status: 'applied',
    at: '2026-08-16T00:01:00Z',
  })
  if (applied.status !== 'applied' || !applied.appliedAt) throw new Error('apply transition missing evidence')
  const replayedApply = await ledger.transition({
    subject: event.subject,
    idempotencyKey: event.idempotencyKey,
    status: 'applied',
    at: '2026-08-16T00:01:00Z',
  })
  if (replayedApply.appliedAt !== applied.appliedAt) throw new Error('apply retry changed evidence')

  const failed = await ledger.transition({
    subject: event.subject,
    idempotencyKey: event.idempotencyKey,
    status: 'failed',
    at: '2026-08-16T00:02:00Z',
    failureCode: 'provider_revoke_unverified',
  })
  if (failed.status !== 'failed' || failed.failureCode !== 'provider_revoke_unverified') {
    throw new Error('failure transition missing evidence')
  }
  try {
    await ledger.transition({
      subject: event.subject,
      idempotencyKey: event.idempotencyKey,
      status: 'verified',
      at: '2026-08-16T00:03:00Z',
    })
    throw new Error('failed event was revived')
  } catch (error) {
    if (!(error instanceof Error) || error.message !== 'ledger_event_failed') throw error
  }
})

Deno.test('ledger port rejects incomplete failure evidence and content-shaped fields', async () => {
  const ledger = createInMemoryDeletionLedger()
  await ledger.append(event)
  try {
    await ledger.transition({
      subject: event.subject,
      idempotencyKey: event.idempotencyKey,
      status: 'failed',
      at: '2026-08-16T00:04:00Z',
    })
    throw new Error('failure without code was accepted')
  } catch (error) {
    if (!(error instanceof Error) || error.message !== 'failure_code_required') throw error
  }

  const stored = (await ledger.listForRestore())[0]
  if (!stored || 'prompt' in stored || 'completion' in stored || 'plaintext' in stored || 'secret' in stored) {
    throw new Error('ledger record contains content-shaped fields')
  }
})
