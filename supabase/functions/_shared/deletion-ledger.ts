export type DeletionKind = 'account' | 'lost_key' | 'device_revoke' | 'provider_key_revoke'
export type DeletionStatus = 'recorded' | 'applied' | 'verified' | 'failed'
export type RestoreStatus =
  | 'isolated_restore'
  | 'reconciliation_in_progress'
  | 'verification_pending'
  | 'service_approved'
  | 'restore_quarantined'

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

export interface ControlledRestoreRun {
  runId: string
  status: RestoreStatus
  snapshot: RestoredPrivateMetadata[]
  appliedEventKeys: string[]
  failureCode?: string
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
  record: Pick<DeletionRecord, 'subject' | 'deletionEpoch' | 'kind' | 'deviceIds' | 'providerKeyIds'>,
): ReconciliationResult {
  if (snapshot.subject !== record.subject) throw new Error('subject_mismatch')
  const deviceIds = new Set(unique(record.deviceIds))
  const providerKeyIds = new Set(unique(record.providerKeyIds))

  const removesPrivateContent = record.kind === 'account' || record.kind === 'lost_key'
  return {
    subject: snapshot.subject,
    deletionEpoch: record.deletionEpoch,
    removedCiphertextRowIds: removesPrivateContent ? unique(snapshot.ciphertextRowIds) : [],
    removedWrappedKeyIds: removesPrivateContent ? unique(snapshot.wrappedKeyIds) : [],
    removedDeviceIds: record.kind === 'account' || record.kind === 'lost_key'
      ? unique(snapshot.deviceIds).filter((id) => deviceIds.size === 0 || deviceIds.has(id))
      : record.kind === 'device_revoke'
        ? unique(snapshot.deviceIds).filter((id) => deviceIds.has(id))
        : [],
    removedProviderKeyIds: record.kind === 'account' || record.kind === 'lost_key'
      ? unique(snapshot.providerKeyIds).filter((id) => providerKeyIds.size === 0 || providerKeyIds.has(id))
      : record.kind === 'provider_key_revoke'
        ? unique(snapshot.providerKeyIds).filter((id) => providerKeyIds.has(id))
        : [],
  }
}

export function startControlledRestore(
  runId: string,
  snapshot: readonly RestoredPrivateMetadata[],
): ControlledRestoreRun {
  if (!runId || snapshot.length === 0) throw new Error('invalid_restore_fixture')
  return {
    runId,
    status: 'isolated_restore',
    snapshot: snapshot.map((row) => ({
      subject: row.subject,
      ciphertextRowIds: unique(row.ciphertextRowIds),
      wrappedKeyIds: unique(row.wrappedKeyIds),
      deviceIds: unique(row.deviceIds),
      providerKeyIds: unique(row.providerKeyIds),
    })),
    appliedEventKeys: [],
  }
}

export function applyDeletionLedger(
  run: ControlledRestoreRun,
  records: readonly DeletionRecord[],
): ControlledRestoreRun {
  if (run.status === 'service_approved') return { ...run, snapshot: run.snapshot.map((row) => ({ ...row })) }
  if (run.status === 'restore_quarantined') throw new Error('restore_quarantined')

  const appliedEventKeys = new Set(run.appliedEventKeys)
  const nextSnapshot = run.snapshot.map((row) => ({
    subject: row.subject,
    ciphertextRowIds: [...row.ciphertextRowIds],
    wrappedKeyIds: [...row.wrappedKeyIds],
    deviceIds: [...row.deviceIds],
    providerKeyIds: [...row.providerKeyIds],
  }))
  const nextRun = { ...run, status: 'reconciliation_in_progress' as const, snapshot: nextSnapshot }

  for (const record of records) {
    if (appliedEventKeys.has(record.idempotencyKey)) continue
    if (record.status === 'failed') throw new Error('ledger_event_failed')
    for (const row of nextRun.snapshot) {
      if (row.subject !== record.subject) continue
      const result = reconcileRestoredMetadata(row, record)
      row.ciphertextRowIds = row.ciphertextRowIds.filter((id) => !result.removedCiphertextRowIds.includes(id))
      row.wrappedKeyIds = row.wrappedKeyIds.filter((id) => !result.removedWrappedKeyIds.includes(id))
      row.deviceIds = row.deviceIds.filter((id) => !result.removedDeviceIds.includes(id))
      row.providerKeyIds = row.providerKeyIds.filter((id) => !result.removedProviderKeyIds.includes(id))
    }
    appliedEventKeys.add(record.idempotencyKey)
  }

  return {
    ...nextRun,
    status: 'verification_pending',
    appliedEventKeys: [...appliedEventKeys],
  }
}

export function verifyControlledRestore(
  run: ControlledRestoreRun,
  records: readonly DeletionRecord[],
): ControlledRestoreRun {
  if (run.status !== 'verification_pending') throw new Error('restore_not_ready_for_verification')
  for (const record of records) {
    const row = run.snapshot.find((candidate) => candidate.subject === record.subject)
    if (!row) continue
    const result = reconcileRestoredMetadata(row, record)
    if (
      result.removedCiphertextRowIds.some((id) => row.ciphertextRowIds.includes(id))
      || result.removedWrappedKeyIds.some((id) => row.wrappedKeyIds.includes(id))
      || result.removedDeviceIds.some((id) => row.deviceIds.includes(id))
      || result.removedProviderKeyIds.some((id) => row.providerKeyIds.includes(id))
    ) {
      return { ...run, status: 'restore_quarantined', failureCode: 'deleted_metadata_visible' }
    }
  }
  return { ...run, status: 'service_approved' }
}
