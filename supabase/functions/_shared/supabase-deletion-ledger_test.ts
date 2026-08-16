import { createSupabaseDeletionLedger } from './supabase-deletion-ledger.ts'

const event = {
  subject: 'subject-hash-1',
  deletionEpoch: 8,
  kind: 'account' as const,
  deviceIds: ['device-1'],
  providerKeyIds: ['provider-key-1'],
  idempotencyKey: 'account-delete-8',
  createdAt: '2026-08-16T00:00:00Z',
  auditActor: 'synthetic-test',
}

function row(status: 'recorded' | 'applied' | 'verified' | 'failed' = 'recorded') {
  return {
    subject: event.subject,
    deletion_epoch: event.deletionEpoch,
    kind: event.kind,
    device_ids: event.deviceIds,
    provider_key_ids: event.providerKeyIds,
    idempotency_key: event.idempotencyKey,
    created_at: event.createdAt,
    audit_actor: event.auditActor,
    status,
    applied_at: status === 'applied' ? '2026-08-16T00:01:00Z' : null,
    verified_at: status === 'verified' ? '2026-08-16T00:02:00Z' : null,
    failure_code: status === 'failed' ? 'provider_revoke_unverified' : null,
  }
}

Deno.test('Supabase adapter rejects same-project or missing service configuration', () => {
  try {
    createSupabaseDeletionLedger({
      ledgerUrl: 'https://app.supabase.co',
      applicationUrl: 'https://app.supabase.co',
      serviceRoleKey: 'server-only-key',
    })
    throw new Error('same project was accepted')
  } catch (error) {
    if (!(error instanceof Error) || error.message !== 'ledger_must_be_independent') throw error
  }

  try {
    createSupabaseDeletionLedger({
      ledgerUrl: 'https://ledger.supabase.co',
      applicationUrl: 'https://app.supabase.co',
      serviceRoleKey: '',
    })
    throw new Error('missing service key was accepted')
  } catch (error) {
    if (!(error instanceof Error) || error.message !== 'ledger_service_key_required') throw error
  }
})

Deno.test('Supabase adapter appends with fixed metadata allowlist and idempotent readback', async () => {
  const requests: Request[] = []
  const ledger = createSupabaseDeletionLedger({
    ledgerUrl: 'https://ledger.supabase.co',
    applicationUrl: 'https://app.supabase.co',
    serviceRoleKey: 'server-only-key',
    fetchImpl: async (input, init) => {
      const request = new Request(input, init)
      requests.push(request)
      if (request.method === 'POST') return Response.json([])
      return Response.json([row()])
    },
  })

  const result = await ledger.append(event)
  if (result.idempotencyKey !== event.idempotencyKey || result.status !== 'recorded') throw new Error('append readback failed')
  const post = requests.find((request) => request.method === 'POST')
  if (!post) throw new Error('append request missing')
  if (post.headers.get('Authorization') !== 'Bearer server-only-key') throw new Error('server auth header missing')
  const payload = JSON.parse(await post.text()) as Record<string, unknown>
  if ('prompt' in payload || 'completion' in payload || 'plaintext' in payload || 'secret' in payload) {
    throw new Error('content-shaped field was sent')
  }
  if (payload.idempotency_key !== event.idempotencyKey) throw new Error('idempotency key missing')
})

Deno.test('Supabase adapter uses optimistic status transitions and safe retries', async () => {
  let current = row()
  const requests: Request[] = []
  const ledger = createSupabaseDeletionLedger({
    ledgerUrl: 'https://ledger.supabase.co',
    applicationUrl: 'https://app.supabase.co',
    serviceRoleKey: 'server-only-key',
    fetchImpl: async (input, init) => {
      const request = new Request(input, init)
      requests.push(request)
      if (request.method === 'GET') return Response.json([current])
      const patch = JSON.parse(await request.text()) as Record<string, string>
      current = { ...current, ...patch }
      return Response.json([current])
    },
  })

  const applied = await ledger.transition({
    subject: event.subject,
    idempotencyKey: event.idempotencyKey,
    status: 'applied',
    at: '2026-08-16T00:01:00Z',
  })
  if (applied.status !== 'applied' || applied.appliedAt !== '2026-08-16T00:01:00Z') throw new Error('transition failed')
  const retried = await ledger.transition({
    subject: event.subject,
    idempotencyKey: event.idempotencyKey,
    status: 'applied',
    at: '2026-08-16T00:01:00Z',
  })
  if (retried.appliedAt !== applied.appliedAt) throw new Error('retry changed transition evidence')
  const patch = requests.find((request) => request.method === 'PATCH')
  if (!patch || patch.url.includes('prompt') || patch.url.includes('plaintext')) throw new Error('unsafe patch request')
})
