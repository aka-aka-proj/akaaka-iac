/**
 * Controlled synthetic restore fixture — Issue #78 acceptance evidence.
 *
 * This test simulates the complete backup-restore-reconciliation lifecycle
 * using in-memory domain logic (createInMemoryDeletionLedger + core functions).
 *
 * It proves:
 *   1. Synthetic encrypted data can be captured as a "backup-like" snapshot.
 *   2. All 4 deletion kinds (account, lost_key, device_revoke, provider_key_revoke)
 *      are recorded idempotently with monotonic epochs.
 *   3. An old snapshot restored into isolation has deleted metadata removed
 *      by ledger reconciliation, without decrypting any content.
 *   4. Reconciliation replay is idempotent — re-running does not modify results.
 *   5. Non-target subjects are not affected by reconciliation.
 *   6. Verification correctly approves clean restores and quarantines tampered ones.
 *   7. Reconciliation output contains no ciphertext, wrapped keys, or secrets
 *      — only opaque identifiers and status metadata.
 *
 * This fixture does NOT connect to Supabase, Cloudflare, or any provider.
 * It uses createInMemoryDeletionLedger for the ledger port and direct
 * domain function calls for reconciliation. The same logic, when pointed at
 * the actual Cloudflare Durable Object worker via DeletionLedgerPort, would
 * produce equivalent results (the domain logic is identical; only persistence
 * changes).
 */

import {
  applyDeletionLedger,
  reconcileRestoredMetadata,
  startControlledRestore,
  verifyControlledRestore,
  type DeletionEvent,
  type DeletionRecord,
  type RestoredPrivateMetadata,
} from './deletion-ledger.ts'
import { createInMemoryDeletionLedger } from './deletion-ledger-port.ts'

// ──────────────────────────────────────────────
// Fixture helpers
// ──────────────────────────────────────────────

const SUBJ_A = 'stage-fixture-alice'
const SUBJ_B = 'stage-fixture-bob'
const SUBJ_C = 'stage-fixture-carol'

function fail(msg: string): never {
  throw new Error(msg)
}

function snapshot(): RestoredPrivateMetadata[] {
  return [
    {
      subject: SUBJ_A,
      ciphertextRowIds: ['msg-a-1', 'msg-a-2', 'msg-a-3'],
      wrappedKeyIds: ['wk-a-1', 'wk-a-2'],
      deviceIds: ['dev-a-phone', 'dev-a-laptop'],
      providerKeyIds: ['pk-a-openrouter', 'pk-a-anthropic'],
    },
    {
      subject: SUBJ_B,
      ciphertextRowIds: ['msg-b-1'],
      wrappedKeyIds: ['wk-b-1'],
      deviceIds: [],
      providerKeyIds: ['pk-b-openrouter'],
    },
    {
      subject: SUBJ_C,
      ciphertextRowIds: ['msg-c-1', 'msg-c-2'],
      wrappedKeyIds: ['wk-c-1'],
      deviceIds: ['dev-c-phone'],
      providerKeyIds: ['pk-c-openrouter'],
    },
  ]
}

function events(): DeletionEvent[] {
  return [
    { subject: SUBJ_A, deletionEpoch: 1, kind: 'account', deviceIds: ['dev-a-phone', 'dev-a-laptop'], providerKeyIds: ['pk-a-openrouter', 'pk-a-anthropic'], idempotencyKey: 'ev-a', createdAt: '2026-08-16T00:00:00Z', auditActor: 'controlled_fixture' },
    { subject: SUBJ_B, deletionEpoch: 1, kind: 'lost_key', deviceIds: [], providerKeyIds: ['pk-b-openrouter'], idempotencyKey: 'ev-b', createdAt: '2026-08-16T00:01:00Z', auditActor: 'controlled_fixture' },
    { subject: SUBJ_C, deletionEpoch: 1, kind: 'device_revoke', deviceIds: ['dev-c-phone'], providerKeyIds: [], idempotencyKey: 'ev-c-dev', createdAt: '2026-08-16T00:02:00Z', auditActor: 'controlled_fixture' },
    { subject: SUBJ_C, deletionEpoch: 2, kind: 'provider_key_revoke', deviceIds: [], providerKeyIds: ['pk-c-openrouter'], idempotencyKey: 'ev-c-pk', createdAt: '2026-08-16T00:03:00Z', auditActor: 'controlled_fixture' },
  ]
}

function sortJoin(arr: string[]): string {
  return [...arr].sort().join(',')
}

// ──────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────

Deno.test('fixture: 4 deletion kinds lifecycle', async () => {
  const snap = snapshot()
  const evts = events()
  const ledger = createInMemoryDeletionLedger()
  const recorded: DeletionRecord[] = []

  // Record all events
  for (const e of evts) {
    const r = await ledger.append(e)
    if (r.status !== 'recorded') fail(`${e.kind} not recorded`)
    recorded.push(r)
  }

  // Idempotent re-append
  for (const e of evts) {
    const r2 = await ledger.append(e)
    const orig = recorded.find((x) => x.idempotencyKey === e.idempotencyKey)!
    if (r2.idempotencyKey !== orig.idempotencyKey) fail('re-append changed key')
  }

  const allRecs = await ledger.listForRestore()
  if (allRecs.length !== 4) fail('expected 4 records')

  // Transition recorded→applied→verified
  for (const rec of recorded) {
    const a = await ledger.transition({ subject: rec.subject, idempotencyKey: rec.idempotencyKey, status: 'applied', at: '2026-08-16T01:00:00Z' })
    if (a.status !== 'applied') fail(`${rec.kind} not applied`)
    const v = await ledger.transition({ subject: rec.subject, idempotencyKey: rec.idempotencyKey, status: 'verified', at: '2026-08-16T02:00:00Z' })
    if (v.status !== 'verified') fail(`${rec.kind} not verified`)
  }

  // Isolated restore + reconciliation
  const run = startControlledRestore('fixture-run-1', snap)
  if (run.status !== 'isolated_restore') fail('not isolated')

  const reconciled = applyDeletionLedger(run, allRecs)
  if (reconciled.status !== 'verification_pending') fail('not held for verification')

  // Replay idempotency
  const replayed = applyDeletionLedger(reconciled, allRecs)
  if (replayed.appliedEventKeys.length !== reconciled.appliedEventKeys.length) fail('replay duplicated keys')

  // Alice (account): everything gone
  const aRow = reconciled.snapshot.find((r) => r.subject === SUBJ_A)!
  if (aRow.ciphertextRowIds.length !== 0) fail('Alice ciphertext not removed')
  if (aRow.wrappedKeyIds.length !== 0) fail('Alice wk not removed')
  if (aRow.deviceIds.length !== 0) fail('Alice devices not removed')
  if (aRow.providerKeyIds.length !== 0) fail('Alice pk not removed')

  // Bob (lost_key): everything gone
  const bRow = reconciled.snapshot.find((r) => r.subject === SUBJ_B)!
  if (bRow.ciphertextRowIds.length !== 0) fail('Bob ciphertext not removed')
  if (bRow.wrappedKeyIds.length !== 0) fail('Bob wk not removed')

  // Carol (device_revoke + provider_key_revoke): only scoped metadata removed
  const cRow = reconciled.snapshot.find((r) => r.subject === SUBJ_C)!
  if (sortJoin(cRow.ciphertextRowIds) !== 'msg-c-1,msg-c-2') fail('Carol ciphertext affected')
  if (sortJoin(cRow.wrappedKeyIds) !== 'wk-c-1') fail('Carol wk affected')
  if (cRow.deviceIds.length !== 0) fail('Carol device not removed')
  if (cRow.providerKeyIds.length !== 0) fail('Carol pk not removed')

  // Verify: clean restore approved
  const approved = verifyControlledRestore(reconciled, allRecs)
  if (approved.status !== 'service_approved') fail('not approved')
  if (approved.snapshot.length !== 3) fail('snapshot lost subjects')
})

Deno.test('fixture: tampered snapshot quarantined', async () => {
  const evts = events()
  const ledger = createInMemoryDeletionLedger()
  for (const e of evts) await ledger.append(e)
  const allRecs = await ledger.listForRestore()

  const reconciled = applyDeletionLedger(startControlledRestore('fixture-q', snapshot()), allRecs)

  // Re-add deleted data to simulate backup leak
  const tampered = {
    ...reconciled,
    snapshot: reconciled.snapshot.map((r) =>
      r.subject === SUBJ_A ? { ...r, ciphertextRowIds: [...r.ciphertextRowIds, 'msg-a-leaked'] } : r
    ),
  }

  const q = verifyControlledRestore(tampered, allRecs)
  if (q.status !== 'restore_quarantined') fail('not quarantined')
  if (q.failureCode !== 'deleted_metadata_visible') fail('wrong failure code')
})

Deno.test('fixture: no content fields in records or reconciliation', async () => {
  const evts = events()
  const ledger = createInMemoryDeletionLedger()
  for (const e of evts) await ledger.append(e)
  const allRecs = await ledger.listForRestore()

  const banned = ['prompt', 'completion', 'plaintext', 'ciphertext', 'secret', 'privateKey', 'vaultKey', 'providerKey', 'token']
  for (const rec of allRecs) {
    for (const field of banned) {
      if (Object.keys(rec).includes(field)) fail(`record has forbidden: ${field}`)
    }
  }

  const res = reconcileRestoredMetadata(
    snapshot()[0],
    { subject: SUBJ_A, deletionEpoch: 1, kind: 'account', deviceIds: ['dev-a-phone'], providerKeyIds: ['pk-a-openrouter'] },
  )
  for (const field of banned) {
    if (Object.keys(res).includes(field)) fail(`result has forbidden: ${field}`)
  }
})

Deno.test('fixture: stale epoch rejected', async () => {
  const ledger = createInMemoryDeletionLedger()
  await ledger.append({ subject: SUBJ_A, deletionEpoch: 2, kind: 'account', deviceIds: [], providerKeyIds: [], idempotencyKey: 'epoch-2', createdAt: '2026-08-16T00:00:00Z', auditActor: 'controlled_fixture' })

  let rejected = false
  try {
    await ledger.append({ subject: SUBJ_A, deletionEpoch: 1, kind: 'lost_key', deviceIds: [], providerKeyIds: [], idempotencyKey: 'epoch-1', createdAt: '2026-08-16T00:01:00Z', auditActor: 'controlled_fixture' })
  } catch (e) {
    rejected = e instanceof Error && e.message === 'stale_deletion_epoch'
  }
  if (!rejected) fail('stale epoch not rejected')
})

Deno.test('fixture: cross-subject isolation', async () => {
  const ledger = createInMemoryDeletionLedger()
  await ledger.append({ subject: SUBJ_A, deletionEpoch: 1, kind: 'account', deviceIds: [], providerKeyIds: [], idempotencyKey: 'cross', createdAt: '2026-08-16T00:00:00Z', auditActor: 'controlled_fixture' })
  const allRecs = await ledger.listForRestore()

  const reconciled = applyDeletionLedger(startControlledRestore('fixture-cross', snapshot()), allRecs)
  const row = reconciled.snapshot.find((r) => r.subject === SUBJ_C)!
  if (sortJoin(row.ciphertextRowIds) !== 'msg-c-1,msg-c-2') fail('Carol ciphertext affected')
  if (sortJoin(row.wrappedKeyIds) !== 'wk-c-1') fail('Carol wk affected')
  if (sortJoin(row.deviceIds) !== 'dev-c-phone') fail('Carol device affected')
  if (sortJoin(row.providerKeyIds) !== 'pk-c-openrouter') fail('Carol pk affected')
})