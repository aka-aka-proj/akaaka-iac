export type DeletionKind = 'account' | 'lost_key' | 'device_revoke' | 'provider_key_revoke'
export type DeletionStatus = 'recorded' | 'applied' | 'verified' | 'failed'

export interface DeletionEvent {
  subject: string
  deletionEpoch: number
  kind: DeletionKind
  deviceIds: string[]
  providerKeyIds: string[]
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

export interface TransitionInput {
  subject: string
  idempotencyKey: string
  status: Exclude<DeletionStatus, 'recorded'>
  at: string
  failureCode?: string
}

const eventKeys = new Set(['subject', 'deletionEpoch', 'kind', 'deviceIds', 'providerKeyIds', 'idempotencyKey', 'createdAt', 'auditActor'])
const transitionKeys = new Set(['subject', 'idempotencyKey', 'status', 'at', 'failureCode'])
const kinds = new Set<DeletionKind>(['account', 'lost_key', 'device_revoke', 'provider_key_revoke'])
const statuses = new Set<Exclude<DeletionStatus, 'recorded'>>(['applied', 'verified', 'failed'])

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function stringValue(value: unknown, name: string): string {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${name}_required`)
  return value
}

function stringArray(value: unknown, name: string): string[] {
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== 'string' || !entry.trim())) throw new Error(`${name}_invalid`)
  return [...new Set(value)]
}

function assertKeys(value: Record<string, unknown>, allowed: Set<string>): void {
  if (Object.keys(value).some((key) => !allowed.has(key))) throw new Error('invalid_request_fields')
}

export function parseEvent(value: unknown, stageOnly = true): DeletionEvent {
  if (!record(value)) throw new Error('event_required')
  assertKeys(value, eventKeys)
  const subject = stringValue(value.subject, 'subject')
  const auditActor = stringValue(value.auditActor, 'audit_actor')
  if (stageOnly && (!subject.startsWith('stage-fixture-') || auditActor !== 'controlled_fixture')) throw new Error('stage_fixture_required')
  if (typeof value.deletionEpoch !== 'number' || !Number.isSafeInteger(value.deletionEpoch) || value.deletionEpoch < 1) throw new Error('deletion_epoch_invalid')
  if (typeof value.kind !== 'string' || !kinds.has(value.kind as DeletionKind)) throw new Error('kind_invalid')
  return {
    subject,
    deletionEpoch: value.deletionEpoch,
    kind: value.kind as DeletionKind,
    deviceIds: stringArray(value.deviceIds, 'device_ids'),
    providerKeyIds: stringArray(value.providerKeyIds, 'provider_key_ids'),
    idempotencyKey: stringValue(value.idempotencyKey, 'idempotency_key'),
    createdAt: stringValue(value.createdAt, 'created_at'),
    auditActor,
  }
}

export function parseTransition(value: unknown, stageOnly = true): TransitionInput {
  if (!record(value)) throw new Error('transition_required')
  assertKeys(value, transitionKeys)
  const subject = stringValue(value.subject, 'subject')
  if (stageOnly && !subject.startsWith('stage-fixture-')) throw new Error('stage_fixture_required')
  if (typeof value.status !== 'string' || !statuses.has(value.status as Exclude<DeletionStatus, 'recorded'>)) throw new Error('status_invalid')
  const failureCode = value.failureCode
  if (value.status === 'failed' && (typeof failureCode !== 'string' || !failureCode.trim())) throw new Error('failure_code_required')
  if (value.status !== 'failed' && failureCode !== undefined) throw new Error('failure_code_not_allowed')
  return {
    subject,
    idempotencyKey: stringValue(value.idempotencyKey, 'idempotency_key'),
    status: value.status as Exclude<DeletionStatus, 'recorded'>,
    at: stringValue(value.at, 'transition_at'),
    failureCode: failureCode as string | undefined,
  }
}

const order: Record<DeletionStatus, number> = { recorded: 0, applied: 1, verified: 2, failed: 3 }

export function transitionRecord(current: DeletionRecord, input: TransitionInput): DeletionRecord {
  if (current.subject !== input.subject) throw new Error('ledger_subject_mismatch')
  if (input.status === 'failed' && !input.failureCode) throw new Error('failure_code_required')
  if (current.status === input.status) {
    if (input.status === 'failed' && current.failureCode !== input.failureCode) throw new Error('invalid_ledger_transition')
    return current
  }
  if (current.status === 'failed' && input.status !== 'applied') throw new Error('ledger_event_failed')
  if (order[input.status] < order[current.status] && !(current.status === 'failed' && input.status === 'applied')) {
    throw new Error('invalid_ledger_transition')
  }
  return {
    ...current,
    status: input.status,
    appliedAt: input.status === 'applied' ? input.at : current.appliedAt,
    verifiedAt: input.status === 'verified' ? input.at : current.verifiedAt,
    failureCode: input.status === 'failed' ? input.failureCode : input.status === 'applied' ? undefined : current.failureCode,
  }
}
