import { createCloudflareDeletionLedger } from './cloudflare-deletion-ledger.ts'
import type { DeletionRecord } from './deletion-ledger.ts'

const event = {
  subject: 'stage-fixture-user-1', deletionEpoch: 1, kind: 'account' as const, deviceIds: [], providerKeyIds: [],
  idempotencyKey: 'fixture-1', createdAt: '2026-08-16T00:00:00Z', auditActor: 'controlled_fixture',
}

Deno.test('Cloudflare adapter requires an independent worker and auth token', () => {
  for (const config of [
    { workerUrl: 'https://app.example.com/ledger', applicationUrl: 'https://app.example.com', authToken: 'token' },
    { workerUrl: 'https://ledger.example.com', applicationUrl: 'https://app.example.com', authToken: '' },
  ]) {
    let rejected = false
    try { createCloudflareDeletionLedger(config) } catch { rejected = true }
    if (!rejected) throw new Error('unsafe_cloudflare_config_accepted')
  }
})

Deno.test('Cloudflare adapter uses server token and metadata-only routes', async () => {
  const requests: Request[] = []
  let current: DeletionRecord = { ...event, status: 'recorded' }
  const ledger = createCloudflareDeletionLedger({
    workerUrl: 'https://ledger.example.com', applicationUrl: 'https://app.example.com', authToken: 'server-only-token',
    fetchImpl: (input, init) => {
      const request = new Request(input, init)
      requests.push(request)
      if (request.method === 'GET') return Promise.resolve(Response.json({ records: [current] }))
      if (request.method === 'PATCH') { current = { ...current, status: 'applied', appliedAt: '2026-08-16T00:01:00Z' }; return Promise.resolve(Response.json({ record: current })) }
      return Promise.resolve(Response.json({ record: current }))
    },
  })
  await ledger.append(event)
  const applied = await ledger.transition({ subject: event.subject, idempotencyKey: event.idempotencyKey, status: 'applied', at: '2026-08-16T00:01:00Z' })
  if (applied.status !== 'applied') throw new Error('cloudflare_transition_failed')
  const request = requests.find((candidate) => candidate.method === 'PATCH')
  if (!request || request.headers.get('Authorization') !== 'Bearer server-only-token' || request.url.includes('prompt')) throw new Error('unsafe_cloudflare_request')
  const body = await request!.json() as Record<string, unknown>
  if (body.subject !== event.subject || body.idempotencyKey !== event.idempotencyKey || body.status !== 'applied' || body.at !== '2026-08-16T00:01:00Z' || 'operation' in body) {
    throw new Error('unsafe_cloudflare_transition_body')
  }
})
