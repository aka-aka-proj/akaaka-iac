import { DurableObject } from 'cloudflare:workers'
import { isRetentionEligible, parseEvent, parseTransition, RETENTION_CLEANUP_BATCH_SIZE, transitionRecord, type DeletionEvent, type DeletionRecord } from './ledger'

export interface Env {
  LEDGER: DurableObjectNamespace
  LEDGER_AUTH_TOKEN: string
  LEDGER_MODE: string
  LEDGER_RETENTION_DAYS: string
}

type Row = Record<string, unknown>

const headers = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers })
}

function stableError(error: unknown): string {
  const message = error instanceof Error ? error.message : ''
  return /^[a-z0-9_]+$/.test(message) ? message : 'ledger_provider_failed'
}

async function secretMatches(expected: string, received: string | null): Promise<boolean> {
  if (!received) return false
  const encoder = new TextEncoder()
  const [expectedHash, receivedHash] = await Promise.all([
    crypto.subtle.digest('SHA-256', encoder.encode(`akaaka-ledger:${expected}`)),
    crypto.subtle.digest('SHA-256', encoder.encode(`akaaka-ledger:${received}`)),
  ])
  const left = new Uint8Array(expectedHash)
  const right = new Uint8Array(receivedHash)
  return left.length === right.length && left.every((value, index) => value === right[index])
}

function recordFromRow(row: Row): DeletionRecord {
  return {
    subject: String(row.subject), deletionEpoch: Number(row.deletion_epoch), kind: row.kind as DeletionEvent['kind'],
    deviceIds: JSON.parse(String(row.device_ids)), providerKeyIds: JSON.parse(String(row.provider_key_ids)),
    idempotencyKey: String(row.idempotency_key), createdAt: String(row.created_at), auditActor: String(row.audit_actor),
    status: row.status as DeletionRecord['status'],
    appliedAt: row.applied_at ? String(row.applied_at) : undefined,
    verifiedAt: row.verified_at ? String(row.verified_at) : undefined,
    failureCode: row.failure_code ? String(row.failure_code) : undefined,
  }
}

function recordParams(record: DeletionEvent): unknown[] {
  return [record.subject, record.deletionEpoch, record.kind, JSON.stringify(record.deviceIds), JSON.stringify(record.providerKeyIds), record.idempotencyKey, record.createdAt, record.auditActor]
}

function retentionDays(value: string | undefined): number {
  const parsed = Number(value)
  if (!Number.isSafeInteger(parsed) || parsed < 1) throw new Error('ledger_retention_not_configured')
  return parsed
}

export class DeletionLedger extends DurableObject {
  private readonly ctx: DurableObjectState

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    this.ctx = ctx
    this.ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS ledger_events (
      subject TEXT NOT NULL,
      deletion_epoch INTEGER NOT NULL,
      kind TEXT NOT NULL,
      device_ids TEXT NOT NULL,
      provider_key_ids TEXT NOT NULL,
      idempotency_key TEXT PRIMARY KEY,
      created_at TEXT NOT NULL,
      audit_actor TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'recorded',
      applied_at TEXT,
      verified_at TEXT,
      failure_code TEXT
    )`)
    this.ctx.storage.sql.exec('CREATE INDEX IF NOT EXISTS ledger_events_subject_created_idx ON ledger_events(subject, created_at, idempotency_key)')
  }

  async fetch(request: Request): Promise<Response> {
    try {
      const url = new URL(request.url)
      if (request.method === 'POST' && url.pathname === '/append') {
        const event = parseEvent(await request.json())
        const existing = this.ctx.storage.sql.exec('SELECT * FROM ledger_events WHERE idempotency_key = ?', event.idempotencyKey).toArray()
        if (existing.length > 0) {
          const record = recordFromRow(existing[0] as Row)
          return json({ record })
        }
        this.ctx.storage.sql.exec(
          `INSERT INTO ledger_events (subject, deletion_epoch, kind, device_ids, provider_key_ids, idempotency_key, created_at, audit_actor)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
          ...recordParams(event),
        )
        const rows = this.ctx.storage.sql.exec('SELECT * FROM ledger_events WHERE idempotency_key = ?', event.idempotencyKey).toArray()
        if (rows.length !== 1) return json({ error: 'ledger_append_not_found' }, 502)
        const record = recordFromRow(rows[0] as Row)
        return json({ record })
      }
      if (request.method === 'GET' && url.pathname === '/list') {
        const subject = url.searchParams.get('subject')
        if (!subject) return json({ error: 'subject_required' }, 400)
        const rows = this.ctx.storage.sql.exec('SELECT * FROM ledger_events WHERE subject = ? ORDER BY created_at ASC, idempotency_key ASC', subject).toArray()
        return json({ records: rows.map((row) => recordFromRow(row as Row)), count: rows.length })
      }
      if (request.method === 'GET' && url.pathname === '/health') {
        const rows = this.ctx.storage.sql.exec('SELECT count(*) as count FROM ledger_events').toArray()
        return json({ status: 'ok', recordCount: Number((rows[0] as Row).count ?? 0) })
      }
      if (request.method === 'POST' && url.pathname === '/cleanup') {
        const input = await request.json() as { now?: unknown; retentionDays?: unknown }
        if (typeof input.now !== 'string' || typeof input.retentionDays !== 'number') return json({ error: 'cleanup_request_invalid' }, 400)
        const candidates = this.ctx.storage.sql.exec(
          'SELECT * FROM ledger_events WHERE status = ? ORDER BY created_at ASC, idempotency_key ASC LIMIT ?',
          'verified', RETENTION_CLEANUP_BATCH_SIZE,
        ).toArray()
        let deletedCount = 0
        for (const row of candidates) {
          const record = recordFromRow(row as Row)
          if (!isRetentionEligible(record, input.now, input.retentionDays)) continue
          const result = this.ctx.storage.sql.exec(
            'DELETE FROM ledger_events WHERE idempotency_key = ? AND status = ?',
            record.idempotencyKey, 'verified',
          )
          if (result.rowsWritten === 1) deletedCount += 1
        }
        return json({ examinedCount: candidates.length, deletedCount })
      }
      if (request.method === 'PATCH' && url.pathname === '/transition') {
        const input = parseTransition(await request.json())
        const rows = this.ctx.storage.sql.exec('SELECT * FROM ledger_events WHERE idempotency_key = ?', input.idempotencyKey).toArray()
        if (rows.length !== 1) return json({ error: 'ledger_event_not_found' }, 404)
        const current = recordFromRow(rows[0] as Row)
        const next = transitionRecord(current, input)
        if (next !== current) {
          const result = this.ctx.storage.sql.exec(
            `UPDATE ledger_events SET status = ?, applied_at = ?, verified_at = ?, failure_code = ?
             WHERE idempotency_key = ? AND subject = ? AND status = ?`,
            next.status, next.appliedAt ?? null, next.verifiedAt ?? null, next.failureCode ?? null,
            input.idempotencyKey, input.subject, current.status,
          )
          if (result.rowsWritten !== 1) return json({ error: 'ledger_transition_conflict' }, 409)
        }
        return json({ record: next })
      }
      return json({ error: 'not_found' }, 404)
    } catch (error) {
      return json({ error: stableError(error) }, 400)
    }
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers })
    if (env.LEDGER_MODE !== 'stage' || !env.LEDGER_AUTH_TOKEN) return json({ error: 'ledger_provider_not_configured' }, 503)
    if (!(await secretMatches(env.LEDGER_AUTH_TOKEN, request.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? null))) {
      return json({ error: 'unauthorized' }, 401)
    }
    const url = new URL(request.url)
    const objectId = env.LEDGER.idFromName('stage-ledger')
    const stub = env.LEDGER.get(objectId)
    if (url.pathname === '/v1/ledger/events' && request.method === 'POST') {
      return stub.fetch('https://ledger.internal/append', request)
    }
    if (url.pathname === '/v1/ledger/events' && request.method === 'GET') {
      return stub.fetch(`https://ledger.internal/list?subject=${encodeURIComponent(url.searchParams.get('subject') ?? '')}`)
    }
    if (url.pathname === '/v1/ledger/events/transition' && request.method === 'PATCH') {
      return stub.fetch('https://ledger.internal/transition', request)
    }
    return json({ error: 'method_not_allowed' }, 405)
  },
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    if (env.LEDGER_MODE !== 'stage' || !env.LEDGER_AUTH_TOKEN) return
    const configuredRetentionDays = retentionDays(env.LEDGER_RETENTION_DAYS)
    const objectId = env.LEDGER.idFromName('stage-ledger')
    const stub = env.LEDGER.get(objectId)
    const cleanup = await stub.fetch('https://ledger.internal/cleanup', {
      method: 'POST',
      body: JSON.stringify({ now: new Date().toISOString(), retentionDays: configuredRetentionDays }),
    })
    if (!cleanup.ok) throw new Error('ledger_cleanup_failed')
    const response = await stub.fetch('https://ledger.internal/health')
    if (!response.ok) throw new Error('ledger_health_failed')
  },
}
