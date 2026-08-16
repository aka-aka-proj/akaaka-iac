import {
  applyDeletionLedger,
  reconcileRestoredMetadata,
  recordDeletionEvent,
  startControlledRestore,
  verifyControlledRestore,
} from './deletion-ledger.ts'

const event = {
  subject: 'subject-hash-1',
  deletionEpoch: 4,
  kind: 'account' as const,
  deviceIds: ['device-1'],
  providerKeyIds: ['provider-key-1'],
  idempotencyKey: 'event-1',
  createdAt: '2026-08-16T00:00:00Z',
  auditActor: 'account-deletion-workflow',
}

Deno.test('deletion ledger events are idempotent and content-free', () => {
  const first = recordDeletionEvent([], event)
  const duplicate = recordDeletionEvent(first, event)
  if (duplicate.length !== 1 || duplicate[0]?.status !== 'recorded') throw new Error('duplicate event changed ledger')
  if ('prompt' in duplicate[0]! || 'completion' in duplicate[0]! || 'plaintext' in duplicate[0]!) {
    throw new Error('ledger contains content')
  }
})

Deno.test('stale deletion epochs cannot reverse a newer deletion', () => {
  const records = recordDeletionEvent([], event)
  try {
    recordDeletionEvent(records, { ...event, deletionEpoch: 3, idempotencyKey: 'event-2' })
    throw new Error('stale epoch was accepted')
  } catch (error) {
    if (!(error instanceof Error) || error.message !== 'stale_deletion_epoch') throw error
  }
})

Deno.test('restore reconciliation removes matching private metadata without decrypting content', () => {
  const result = reconcileRestoredMetadata({
    subject: event.subject,
    ciphertextRowIds: ['message-1', 'message-1'],
    wrappedKeyIds: ['wrapped-1'],
    deviceIds: ['device-1', 'other-device'],
    providerKeyIds: ['provider-key-1', 'other-provider-key'],
  }, event)

  if (result.deletionEpoch !== 4) throw new Error('wrong deletion epoch')
  if (result.removedCiphertextRowIds.join() !== 'message-1') throw new Error('ciphertext was not removed')
  if (result.removedWrappedKeyIds.join() !== 'wrapped-1') throw new Error('wrapped key was not removed')
  if (result.removedDeviceIds.join() !== 'device-1') throw new Error('wrong device removal')
  if (result.removedProviderKeyIds.join() !== 'provider-key-1') throw new Error('wrong provider key removal')
})

Deno.test('controlled restore fixture is quarantined until reconciliation and verification approve service', () => {
  const target = {
    subject: event.subject,
    ciphertextRowIds: ['message-1'],
    wrappedKeyIds: ['wrapped-1'],
    deviceIds: ['device-1'],
    providerKeyIds: ['provider-key-1'],
  }
  const nonTarget = {
    subject: 'subject-hash-2',
    ciphertextRowIds: ['message-2'],
    wrappedKeyIds: ['wrapped-2'],
    deviceIds: ['device-2'],
    providerKeyIds: ['provider-key-2'],
  }
  const run = startControlledRestore('restore-run-1', [target, nonTarget])
  if (run.status !== 'isolated_restore') throw new Error('restore was not isolated')

  const records = recordDeletionEvent([], event)
  const reconciled = applyDeletionLedger(run, records)
  if (reconciled.status !== 'verification_pending') throw new Error('restore was not held for verification')
  const approved = verifyControlledRestore(reconciled, records)
  if (approved.status !== 'service_approved') throw new Error('restore was not approved')
  if (approved.snapshot[0]?.ciphertextRowIds.length !== 0) throw new Error('deleted ciphertext remained visible')
  if (approved.snapshot[1]?.ciphertextRowIds.join() !== 'message-2') throw new Error('non-target was changed')
})

Deno.test('controlled restore replay is idempotent and a failed verification remains quarantined', () => {
  const run = startControlledRestore('restore-run-2', [{
    subject: event.subject,
    ciphertextRowIds: ['message-1'],
    wrappedKeyIds: ['wrapped-1'],
    deviceIds: ['device-1'],
    providerKeyIds: ['provider-key-1'],
  }])
  const records = recordDeletionEvent([], event)
  const reconciled = applyDeletionLedger(run, records)
  const replayed = applyDeletionLedger(reconciled, records)
  if (replayed.snapshot[0]?.ciphertextRowIds.length !== 0) throw new Error('replay restored deleted ciphertext')
  if (replayed.appliedEventKeys.length !== 1) throw new Error('replay duplicated ledger event')

  const tampered = {
    ...reconciled,
    snapshot: reconciled.snapshot.map((row) => ({ ...row, ciphertextRowIds: ['message-1'] })),
  }
  const quarantined = verifyControlledRestore(tampered, records)
  if (quarantined.status !== 'restore_quarantined' || quarantined.failureCode !== 'deleted_metadata_visible') {
    throw new Error('verification failure did not quarantine restore')
  }
})

Deno.test('device and provider revocations do not delete unrelated ciphertext', () => {
  const fixture = {
    subject: event.subject,
    ciphertextRowIds: ['message-1'],
    wrappedKeyIds: ['wrapped-1'],
    deviceIds: ['device-1', 'device-2'],
    providerKeyIds: ['provider-key-1', 'provider-key-2'],
  }
  const deviceEvent = { ...event, kind: 'device_revoke' as const, deviceIds: ['device-1'], providerKeyIds: [], idempotencyKey: 'device-event' }
  const providerEvent = { ...event, kind: 'provider_key_revoke' as const, deviceIds: [], providerKeyIds: ['provider-key-1'], idempotencyKey: 'provider-event' }
  const records = [deviceEvent, providerEvent].map((item) => ({ ...item, status: 'recorded' as const }))
  const run = applyDeletionLedger(startControlledRestore('restore-run-3', [fixture]), records)
  const row = run.snapshot[0]
  if (row?.ciphertextRowIds.join() !== 'message-1') throw new Error('revocation deleted ciphertext')
  if (row?.deviceIds.join() !== 'device-2') throw new Error('device revoke was not scoped')
  if (row?.providerKeyIds.join() !== 'provider-key-2') throw new Error('provider revoke was not scoped')
})
