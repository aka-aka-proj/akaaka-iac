import { assertLedgerTransition, type DeletionLedgerPort, type LedgerStatusTransition } from './deletion-ledger-port.ts'
import type { DeletionEvent, DeletionRecord, DeletionStatus } from './deletion-ledger.ts'

type FetchLike = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>

export interface CloudflareDeletionLedgerConfig {
  workerUrl: string
  authToken: string
  applicationUrl: string
  fetchImpl?: FetchLike
}

const safeColumns = new Set(['subject', 'deletionEpoch', 'kind', 'deviceIds', 'providerKeyIds', 'idempotencyKey', 'createdAt', 'auditActor', 'status', 'appliedAt', 'verifiedAt', 'failureCode'])

function url(value: string, name: string): URL {
  if (!value.trim()) throw new Error(`${name}_required`)
  try { return new URL(value) } catch { throw new Error(`${name}_invalid`) }
}

function safeRecord(value: unknown): DeletionRecord {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error('ledger_response_invalid')
  const record = value as Record<string, unknown>
  if (Object.keys(record).some((key) => !safeColumns.has(key))) throw new Error('ledger_response_unsafe')
  if (typeof record.subject !== 'string' || typeof record.deletionEpoch !== 'number' || typeof record.kind !== 'string' || typeof record.idempotencyKey !== 'string' || typeof record.createdAt !== 'string' || typeof record.auditActor !== 'string' || typeof record.status !== 'string') throw new Error('ledger_response_invalid')
  return {
    subject: record.subject,
    deletionEpoch: record.deletionEpoch,
    kind: record.kind as DeletionEvent['kind'],
    deviceIds: Array.isArray(record.deviceIds) ? record.deviceIds.filter((value): value is string => typeof value === 'string') : [],
    providerKeyIds: Array.isArray(record.providerKeyIds) ? record.providerKeyIds.filter((value): value is string => typeof value === 'string') : [],
    idempotencyKey: record.idempotencyKey,
    createdAt: record.createdAt,
    auditActor: record.auditActor,
    status: record.status as DeletionStatus,
    appliedAt: typeof record.appliedAt === 'string' ? record.appliedAt : undefined,
    verifiedAt: typeof record.verifiedAt === 'string' ? record.verifiedAt : undefined,
    failureCode: typeof record.failureCode === 'string' ? record.failureCode : undefined,
  }
}

function providerError(response: Response, operation: string): Error {
  return new Error(`ledger_${operation}_failed_${response.status}`)
}

export function createCloudflareDeletionLedger(config: CloudflareDeletionLedgerConfig): DeletionLedgerPort {
  const workerUrl = url(config.workerUrl, 'ledger_url')
  const applicationUrl = url(config.applicationUrl, 'application_url')
  if (workerUrl.origin === applicationUrl.origin) throw new Error('ledger_must_be_independent')
  if (!config.authToken.trim()) throw new Error('ledger_auth_token_required')
  const fetchImpl = config.fetchImpl ?? fetch

  const request = async <T>(path: string, init: RequestInit, operation: string): Promise<T> => {
    const response = await fetchImpl(new URL(path, workerUrl), {
      ...init,
      headers: {
        Authorization: `Bearer ${config.authToken}`,
        'Content-Type': 'application/json',
        ...(init.headers ?? {}),
      },
    })
    if (!response.ok) throw providerError(response, operation)
    try { return await response.json() as T } catch { throw new Error(`ledger_${operation}_response_invalid`) }
  }

  return {
    async append(event) {
      const body = await request<{ record: unknown }>('/v1/ledger/events', { method: 'POST', body: JSON.stringify(event) }, 'append')
      return safeRecord(body.record)
    },
    async listForRestore(subject) {
      if (!subject) throw new Error('ledger_subject_required')
      const body = await request<{ records: unknown[] }>(`/v1/ledger/events?subject=${encodeURIComponent(subject)}`, { method: 'GET' }, 'list')
      if (!Array.isArray(body.records)) throw new Error('ledger_list_response_invalid')
      return body.records.map(safeRecord)
    },
    async transition(input: LedgerStatusTransition) {
      const current = (await this.listForRestore(input.subject)).find((record) => record.idempotencyKey === input.idempotencyKey)
      if (!current) throw new Error('ledger_event_not_found')
      assertLedgerTransition(current.status, input.status)
      if (input.status === 'failed' && !input.failureCode) throw new Error('failure_code_required')
      if (current.status === input.status) {
        if (input.status === 'failed' && current.failureCode !== input.failureCode) throw new Error('invalid_ledger_transition')
        return current
      }
      const body = await request<{ record: unknown }>('/v1/ledger/events/transition', {
        method: 'PATCH',
        body: JSON.stringify(input),
      }, 'transition')
      return safeRecord(body.record)
    },
  }
}
