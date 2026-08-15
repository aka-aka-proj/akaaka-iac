export type DeletionKind = 'account' | 'lost_key' | 'device_revoke' | 'provider_key_revoke'
export type DeletionStatus = 'recorded' | 'applied' | 'verified' | 'failed'

export interface DeletionEvent {
  subject: string
  deletionEpoch: number
  kind: DeletionKind
  deviceIds?: string[]
  providerKeyIds?: string[]
  idempotencyKey: string
  createdAt: string
  auditActor: string
}

export interface DeletionRecord extends DeletionEvent {
  status: DeletionStatus
  appliedAt?: string
  verifiedAt?: string
  failureCode?: string
}

export interface RestoredPrivateMetadata {
  subject: string
  ciphertextRowIds: string[]
  wrappedKeyIds: string[]
  deviceIds: string[]
  providerKeyIds: string[]
}

export interface ReconciliationResult {
  subject: string
  deletionEpoch: number
  removedCiphertextRowIds: string[]
  removedWrappedKeyIds: string[]
  removedDeviceIds: string[]
  removedProviderKeyIds: string[]
}

function unique(values: string[] | undefined): string[] {
  return [...new Set((values ?? []).filter(Boolean))]
}

export function recordDeletionEvent(
  records: readonly DeletionRecord[],
  event: DeletionEvent,
): DeletionRecord[] {
  if (!event.subject || !event.idempotencyKey || event.deletionEpoch < 1) {
    throw new Error('invalid_deletion_event')
  }
  const duplicate = records.find((record) => record.idempotencyKey === event.idempotencyKey)
  if (duplicate) return [...records]

  const currentEpoch = records
    .filter((record) => record.subject === event.subject)
    .reduce((max, record) => Math.max(max, record.deletionEpoch), 0)
  if (event.deletionEpoch < currentEpoch) throw new Error('stale_deletion_epoch')

  return [...records, {
    ...event,
    deviceIds: unique(event.deviceIds),
    providerKeyIds: unique(event.providerKeyIds),
    status: 'recorded',
  }]
}

export function reconcileRestoredMetadata(
  snapshot: RestoredPrivateMetadata,
  record: Pick<DeletionRecord, 'subject' | 'deletionEpoch' | 'deviceIds' | 'providerKeyIds'>,
): ReconciliationResult {
  if (snapshot.subject !== record.subject) throw new Error('subject_mismatch')
  const deviceIds = new Set(unique(record.deviceIds))
  const providerKeyIds = new Set(unique(record.providerKeyIds))

  return {
    subject: snapshot.subject,
    deletionEpoch: record.deletionEpoch,
    removedCiphertextRowIds: unique(snapshot.ciphertextRowIds),
    removedWrappedKeyIds: unique(snapshot.wrappedKeyIds),
    removedDeviceIds: unique(snapshot.deviceIds).filter((id) => deviceIds.size === 0 || deviceIds.has(id)),
    removedProviderKeyIds: unique(snapshot.providerKeyIds).filter((id) => providerKeyIds.size === 0 || providerKeyIds.has(id)),
  }
}
