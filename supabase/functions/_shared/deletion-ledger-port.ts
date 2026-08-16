import {
  recordDeletionEvent,
  type DeletionEvent,
  type DeletionRecord,
  type DeletionStatus,
} from './deletion-ledger.ts'

export interface LedgerStatusTransition {
  idempotencyKey: string
  status: Exclude<DeletionStatus, 'recorded'>
  at: string
  failureCode?: string
}

/**
 * Provider-neutral port for the independent deletion ledger.
 *
 * Production adapters must implement this port against a durable system that
 * is outside the Supabase backup/PITR restore boundary. This module does not
 * select, configure, or authenticate any provider.
 */
export interface DeletionLedgerPort {
  append(event: DeletionEvent): Promise<DeletionRecord>
  listForRestore(subject?: string): Promise<readonly DeletionRecord[]>
  transition(input: LedgerStatusTransition): Promise<DeletionRecord>
}

const STATUS_ORDER: Record<DeletionStatus, number> = {
  recorded: 0,
  applied: 1,
  verified: 2,
  failed: 3,
}

function cloneRecord(record: DeletionRecord): DeletionRecord {
  return {
    ...record,
    deviceIds: record.deviceIds ? [...record.deviceIds] : undefined,
    providerKeyIds: record.providerKeyIds ? [...record.providerKeyIds] : undefined,
  }
}

export function assertLedgerTransition(current: DeletionStatus, next: DeletionStatus): void {
  if (current === 'failed') throw new Error('ledger_event_failed')
  if (next === 'failed') return
  if (STATUS_ORDER[next] < STATUS_ORDER[current]) throw new Error('invalid_ledger_transition')
}

/** Synthetic-only adapter used by unit tests and controlled fixtures. */
export function createInMemoryDeletionLedger(
  initialRecords: readonly DeletionRecord[] = [],
): DeletionLedgerPort {
  let records = initialRecords.map(cloneRecord)

  return {
    async append(event) {
      const existing = records.find((record) => record.idempotencyKey === event.idempotencyKey)
      if (existing) return cloneRecord(existing)

      records = recordDeletionEvent(records, event)
      const created = records.at(-1)
      if (!created) throw new Error('ledger_append_failed')
      return cloneRecord(created)
    },

    async listForRestore(subject) {
      return records
        .filter((record) => subject === undefined || record.subject === subject)
        .map(cloneRecord)
    },

    async transition(input) {
      const index = records.findIndex((record) => record.idempotencyKey === input.idempotencyKey)
      if (index < 0) throw new Error('ledger_event_not_found')
      const current = records[index]
      assertLedgerTransition(current.status, input.status)
      if (input.status === 'failed' && !input.failureCode) throw new Error('failure_code_required')
      if (current.status === input.status) {
        if (input.status === 'failed' && current.failureCode !== input.failureCode) {
          throw new Error('invalid_ledger_transition')
        }
        return cloneRecord(current)
      }

      const next: DeletionRecord = {
        ...current,
        status: input.status,
        appliedAt: input.status === 'applied' ? input.at : current.appliedAt,
        verifiedAt: input.status === 'verified' ? input.at : current.verifiedAt,
        failureCode: input.status === 'failed' ? input.failureCode : current.failureCode,
      }
      records = [...records.slice(0, index), next, ...records.slice(index + 1)]
      return cloneRecord(next)
    },
  }
}
