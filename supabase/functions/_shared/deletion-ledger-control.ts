import type {
  DeletionEvent,
  DeletionKind,
  DeletionRecord,
  DeletionStatus,
} from './deletion-ledger.ts'

const kinds = new Set<DeletionKind>(['account', 'lost_key', 'device_revoke', 'provider_key_revoke'])
const statuses = new Set<DeletionStatus>(['recorded', 'applied', 'verified', 'failed'])
const transitionStatuses = new Set<Exclude<DeletionStatus, 'recorded'>>(['applied', 'verified', 'failed'])
const operations = new Set(['append', 'list', 'transition'])

export type LedgerControlRequest =
  | { operation: 'append'; event: Omit<DeletionEvent, 'auditActor'> }
  | { operation: 'list'; subject: string }
  | { operation: 'transition'; idempotencyKey: string; status: Exclude<DeletionStatus, 'recorded'>; at: string; failureCode?: string }

export type SafeLedgerRecord = Pick<
  DeletionRecord,
  'subject' | 'deletionEpoch' | 'kind' | 'deviceIds' | 'providerKeyIds' | 'idempotencyKey' | 'createdAt'
  | 'auditActor' | 'status' | 'appliedAt' | 'verifiedAt' | 'failureCode'
>

export function isAdminAal2(
  user: { app_metadata?: Record<string, unknown> | null },
  jwtPayload: Record<string, unknown> | null,
): boolean {
  return user.app_metadata?.role === 'admin' && jwtPayload?.aal === 'aal2'
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function assertKeys(value: Record<string, unknown>, allowed: readonly string[]): void {
  const allowedSet = new Set(allowed)
  if (Object.keys(value).some((key) => !allowedSet.has(key))) throw new Error('invalid_request_fields')
}

function stringArray(value: unknown, field: string): string[] {
  if (value === undefined) return []
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== 'string' || !entry.trim())) {
    throw new Error(`${field}_invalid`)
  }
  return [...new Set(value)]
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${field}_required`)
  return value
}

export function parseStageLedgerRequest(value: unknown): LedgerControlRequest {
  if (!isRecord(value)) throw new Error('invalid_json')
  const operation = value.operation
  if (typeof operation !== 'string' || !operations.has(operation)) throw new Error('invalid_operation')

  if (operation === 'append') {
    if (!isRecord(value.event)) throw new Error('event_required')
    assertKeys(value.event, ['subject', 'deletionEpoch', 'kind', 'deviceIds', 'providerKeyIds', 'idempotencyKey', 'createdAt'])
    const event = value.event
    const subject = requiredString(event.subject, 'subject')
    if (!subject.startsWith('stage-fixture-')) throw new Error('stage_fixture_subject_required')
    if (typeof event.deletionEpoch !== 'number' || !Number.isSafeInteger(event.deletionEpoch) || event.deletionEpoch < 1) {
      throw new Error('deletion_epoch_invalid')
    }
    if (typeof event.kind !== 'string' || !kinds.has(event.kind as DeletionKind)) throw new Error('kind_invalid')
    return {
      operation,
      event: {
        subject,
        deletionEpoch: event.deletionEpoch,
        kind: event.kind as DeletionKind,
        deviceIds: stringArray(event.deviceIds, 'device_ids'),
        providerKeyIds: stringArray(event.providerKeyIds, 'provider_key_ids'),
        idempotencyKey: requiredString(event.idempotencyKey, 'idempotency_key'),
        createdAt: requiredString(event.createdAt, 'created_at'),
      },
    }
  }

  if (operation === 'list') {
    assertKeys(value, ['operation', 'subject'])
    const subject = requiredString(value.subject, 'subject')
    if (!subject.startsWith('stage-fixture-')) throw new Error('stage_fixture_subject_required')
    return { operation, subject }
  }

  assertKeys(value, ['operation', 'idempotencyKey', 'status', 'at', 'failureCode'])
  const idempotencyKey = requiredString(value.idempotencyKey, 'idempotency_key')
  if (typeof value.status !== 'string' || !statuses.has(value.status as DeletionStatus) || !transitionStatuses.has(value.status as Exclude<DeletionStatus, 'recorded'>)) throw new Error('status_invalid')
  const at = requiredString(value.at, 'transition_at')
  if (value.status === 'failed' && typeof value.failureCode !== 'string') throw new Error('failure_code_required')
  if (value.status !== 'failed' && value.failureCode !== undefined) throw new Error('failure_code_not_allowed')
  return { operation: 'transition', idempotencyKey, status: value.status as Exclude<DeletionStatus, 'recorded'>, at, failureCode: value.failureCode as string | undefined }
}

export function toSafeLedgerRecord(record: DeletionRecord): SafeLedgerRecord {
  return {
    subject: record.subject,
    deletionEpoch: record.deletionEpoch,
    kind: record.kind,
    deviceIds: record.deviceIds,
    providerKeyIds: record.providerKeyIds,
    idempotencyKey: record.idempotencyKey,
    createdAt: record.createdAt,
    auditActor: record.auditActor,
    status: record.status,
    appliedAt: record.appliedAt,
    verifiedAt: record.verifiedAt,
    failureCode: record.failureCode,
  }
}
