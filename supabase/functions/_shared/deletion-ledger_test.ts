import {
  reconcileRestoredMetadata,
  recordDeletionEvent,
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
