import {
  assertLedgerTransition,
  type DeletionLedgerPort,
  type LedgerStatusTransition,
} from './deletion-ledger-port.ts'
import type { DeletionEvent, DeletionRecord, DeletionStatus } from './deletion-ledger.ts'

const TABLE = 'deletion_ledger_events'
const COLUMNS = [
  'subject',
  'deletion_epoch',
  'kind',
  'device_ids',
  'provider_key_ids',
  'idempotency_key',
  'created_at',
  'audit_actor',
  'status',
  'applied_at',
  'verified_at',
  'failure_code',
].join(',')

type FetchLike = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>

export interface SupabaseDeletionLedgerConfig {
  ledgerUrl: string
  serviceRoleKey: string
  applicationUrl: string
  fetchImpl?: FetchLike
}

function normalizeUrl(value: string, name: string): URL {
  if (!value.trim()) throw new Error(`${name}_required`)
  try {
    return new URL(value)
  } catch {
    throw new Error(`${name}_invalid`)
  }
}

function cloneRecord(record: DeletionRecord): DeletionRecord {
  return {
    ...record,
    deviceIds: record.deviceIds ? [...record.deviceIds] : undefined,
    providerKeyIds: record.providerKeyIds ? [...record.providerKeyIds] : undefined,
  }
}

function fromRow(row: Record<string, unknown>): DeletionRecord {
  if (
    typeof row.subject !== 'string'
    || typeof row.deletion_epoch !== 'number'
    || typeof row.kind !== 'string'
    || typeof row.idempotency_key !== 'string'
    || typeof row.created_at !== 'string'
    || typeof row.audit_actor !== 'string'
    || typeof row.status !== 'string'
  ) throw new Error('ledger_response_invalid')

  return {
    subject: row.subject,
    deletionEpoch: row.deletion_epoch,
    kind: row.kind as DeletionEvent['kind'],
    deviceIds: Array.isArray(row.device_ids) ? row.device_ids.filter((value): value is string => typeof value === 'string') : [],
    providerKeyIds: Array.isArray(row.provider_key_ids) ? row.provider_key_ids.filter((value): value is string => typeof value === 'string') : [],
    idempotencyKey: row.idempotency_key,
    createdAt: row.created_at,
    auditActor: row.audit_actor,
    status: row.status as DeletionStatus,
    appliedAt: typeof row.applied_at === 'string' ? row.applied_at : undefined,
    verifiedAt: typeof row.verified_at === 'string' ? row.verified_at : undefined,
    failureCode: typeof row.failure_code === 'string' ? row.failure_code : undefined,
  }
}

function responseError(response: Response, operation: string): Error {
  return new Error(`ledger_${operation}_failed_${response.status}`)
}

export function createSupabaseDeletionLedger(config: SupabaseDeletionLedgerConfig): DeletionLedgerPort {
  const ledgerUrl = normalizeUrl(config.ledgerUrl, 'ledger_url')
  const applicationUrl = normalizeUrl(config.applicationUrl, 'application_url')
  if (ledgerUrl.origin === applicationUrl.origin) throw new Error('ledger_must_be_independent')
  if (!config.serviceRoleKey.trim()) throw new Error('ledger_service_key_required')
  const fetchImpl = config.fetchImpl ?? fetch

  const endpoint = (): URL => new URL(`/rest/v1/${TABLE}`, ledgerUrl)
  const request = async <T>(url: URL, init: RequestInit, operation: string): Promise<T> => {
    const response = await fetchImpl(url, {
      ...init,
      headers: {
        apikey: config.serviceRoleKey,
        Authorization: `Bearer ${config.serviceRoleKey}`,
        'Content-Type': 'application/json',
        ...(init.headers ?? {}),
      },
    })
    if (!response.ok) throw responseError(response, operation)
    try {
      return await response.json() as T
    } catch {
      throw new Error(`ledger_${operation}_response_invalid`)
    }
  }

  const list = async (subject?: string): Promise<DeletionRecord[]> => {
    const url = endpoint()
    url.searchParams.set('select', COLUMNS)
    url.searchParams.set('order', 'created_at.asc')
    if (subject !== undefined) url.searchParams.set('subject', `eq.${subject}`)
    const rows = await request<unknown[]>(url, { method: 'GET' }, 'list')
    if (!Array.isArray(rows)) throw new Error('ledger_list_response_invalid')
    return rows.map((row) => fromRow(row as Record<string, unknown>))
  }

  return {
    async append(event) {
      const url = endpoint()
      const payload = {
        subject: event.subject,
        deletion_epoch: event.deletionEpoch,
        kind: event.kind,
        device_ids: event.deviceIds ?? [],
        provider_key_ids: event.providerKeyIds ?? [],
        idempotency_key: event.idempotencyKey,
        created_at: event.createdAt,
        audit_actor: event.auditActor,
        status: 'recorded',
      }
      await request<unknown[]>(url, {
        method: 'POST',
        headers: { Prefer: 'resolution=ignore-duplicates,return=minimal' },
        body: JSON.stringify(payload),
      }, 'append')
      const rows = await list(event.subject)
      const record = rows.find((candidate) => candidate.idempotencyKey === event.idempotencyKey)
      if (!record) throw new Error('ledger_append_not_found')
      return cloneRecord(record)
    },

    async listForRestore(subject) {
      return (await list(subject)).map(cloneRecord)
    },

    async transition(input: LedgerStatusTransition) {
      const current = (await list()).find((record) => record.idempotencyKey === input.idempotencyKey)
      if (!current) throw new Error('ledger_event_not_found')
      assertLedgerTransition(current.status, input.status)
      if (input.status === 'failed' && !input.failureCode) throw new Error('failure_code_required')
      if (current.status === input.status) {
        if (input.status === 'failed' && current.failureCode !== input.failureCode) throw new Error('invalid_ledger_transition')
        return cloneRecord(current)
      }

      const url = endpoint()
      url.searchParams.set('idempotency_key', `eq.${input.idempotencyKey}`)
      url.searchParams.set('status', `eq.${current.status}`)
      const patch: Record<string, string> = { status: input.status }
      if (input.status === 'applied') patch.applied_at = input.at
      if (input.status === 'verified') patch.verified_at = input.at
      if (input.status === 'failed') patch.failure_code = input.failureCode!
      const rows = await request<unknown[]>(url, {
        method: 'PATCH',
        headers: { Prefer: 'return=representation' },
        body: JSON.stringify(patch),
      }, 'transition')
      if (!Array.isArray(rows) || rows.length !== 1) {
        const latest = (await list()).find((record) => record.idempotencyKey === input.idempotencyKey)
        if (latest?.status === input.status) return cloneRecord(latest)
        throw new Error('ledger_transition_conflict')
      }
      return fromRow(rows[0] as Record<string, unknown>)
    },
  }
}
