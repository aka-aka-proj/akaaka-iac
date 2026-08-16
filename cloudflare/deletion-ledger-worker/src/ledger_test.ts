import { parseEvent, parseTransition, transitionRecord, type DeletionRecord } from './ledger.ts'

Deno.test('Cloudflare ledger parser enforces stage metadata boundary', () => {
  const event = parseEvent({
    subject: 'stage-fixture-user-1', deletionEpoch: 1, kind: 'account', deviceIds: [], providerKeyIds: [],
    idempotencyKey: 'fixture-1', createdAt: '2026-08-16T00:00:00Z', auditActor: 'controlled_fixture',
  })
  if (event.subject !== 'stage-fixture-user-1') throw new Error('event_not_parsed')
  for (const invalid of [
    { ...event, prompt: 'secret' },
    { ...event, subject: 'real-user' },
    { ...event, auditActor: 'operator@example.com' },
  ]) {
    let rejected = false
    try { parseEvent(invalid) } catch { rejected = true }
    if (!rejected) throw new Error('unsafe_event_accepted')
  }
})

Deno.test('Cloudflare ledger transition is monotonic and retry-safe', () => {
  const current: DeletionRecord = {
    subject: 'stage-fixture-user-1', deletionEpoch: 1, kind: 'account', deviceIds: [], providerKeyIds: [],
    idempotencyKey: 'fixture-1', createdAt: '2026-08-16T00:00:00Z', auditActor: 'controlled_fixture', status: 'recorded',
  }
  const input = parseTransition({ subject: current.subject, idempotencyKey: current.idempotencyKey, status: 'applied', at: '2026-08-16T00:01:00Z' })
  const applied = transitionRecord(current, input)
  const retry = transitionRecord(applied, input)
  if (retry.appliedAt !== applied.appliedAt || retry.status !== 'applied') throw new Error('retry_not_idempotent')
  let rejected = false
  try { transitionRecord(applied, { ...input, subject: 'stage-fixture-other' }) } catch { rejected = true }
  if (!rejected) throw new Error('cross_subject_transition_accepted')
})

Deno.test('Cloudflare failed provider event can retry with the same idempotency key', () => {
  const current: DeletionRecord = {
    subject: 'stage-fixture-provider-1', deletionEpoch: 1, kind: 'provider_key_revoke', deviceIds: [], providerKeyIds: ['provider-key-1'],
    idempotencyKey: 'provider-revoke-1', createdAt: '2026-08-16T00:00:00Z', auditActor: 'controlled_fixture', status: 'recorded',
  }
  const failed = transitionRecord(current, parseTransition({
    subject: current.subject, idempotencyKey: current.idempotencyKey, status: 'failed', at: '2026-08-16T00:01:00Z',
    failureCode: 'provider_revoke_unverified',
  }))
  let rejected = false
  try {
    transitionRecord(failed, parseTransition({
      subject: current.subject, idempotencyKey: current.idempotencyKey, status: 'verified', at: '2026-08-16T00:02:00Z',
    }))
  } catch (error) {
    rejected = error instanceof Error && error.message === 'ledger_event_failed'
  }
  if (!rejected) throw new Error('failed_event_was_directly_verified')
  const retry = transitionRecord(failed, parseTransition({
    subject: current.subject, idempotencyKey: current.idempotencyKey, status: 'applied', at: '2026-08-16T00:03:00Z',
  }))
  if (retry.status !== 'applied' || retry.failureCode !== undefined || retry.appliedAt !== '2026-08-16T00:03:00Z') {
    throw new Error('failed_event_retry_not_applied')
  }
})
