import { isAdminAal2, parseStageLedgerRequest, readJwtPayload, toSafeLedgerRecord } from './deletion-ledger-control.ts'

Deno.test('stage ledger authorization requires admin role and AAL2', () => {
  if (!isAdminAal2({ app_metadata: { role: 'admin' } }, { aal: 'aal2' })) throw new Error('valid_admin_rejected')
  if (isAdminAal2({ app_metadata: { role: 'admin' } }, { aal: 'aal1' })) throw new Error('aal1_accepted')
  if (isAdminAal2({ app_metadata: { role: 'user' } }, { aal: 'aal2' })) throw new Error('non_admin_accepted')
})

Deno.test('JWT payload decoder reads base64url claims', () => {
  const encode = (value: unknown) => btoa(JSON.stringify(value)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_')
  const payload = readJwtPayload(`Bearer ${encode({ alg: 'none' })}.${encode({ sub: 'fixture', aal: 'aal2', app_metadata: { role: 'admin' } })}.signature`)
  if (payload?.sub !== 'fixture' || payload.aal !== 'aal2' || (payload.app_metadata as Record<string, unknown>)?.role !== 'admin') {
    throw new Error('jwt_payload_not_decoded')
  }
})

Deno.test('stage ledger request accepts only metadata append fields', () => {
  const request = parseStageLedgerRequest({
    operation: 'append',
    event: {
      subject: 'stage-fixture-user-1',
      deletionEpoch: 1,
      kind: 'account',
      deviceIds: ['device-1', 'device-1'],
      providerKeyIds: [],
      idempotencyKey: 'fixture-1',
      createdAt: '2026-08-16T05:00:00Z',
    },
  })
  if (request.operation !== 'append' || request.event.deviceIds?.length !== 1) throw new Error('request_not_normalized')
})

Deno.test('stage ledger request rejects non-fixture and content-shaped fields', () => {
  for (const value of [
    { operation: 'list', subject: 'real-user' },
    { operation: 'transition', subject: 'real-user', idempotencyKey: 'x', status: 'applied', at: 'now' },
    { operation: 'append', event: { subject: 'stage-fixture-user-1', deletionEpoch: 1, kind: 'account', idempotencyKey: 'x', createdAt: 'now', prompt: 'secret' } },
  ]) {
    let rejected = false
    try {
      parseStageLedgerRequest(value)
    } catch {
      rejected = true
    }
    if (!rejected) throw new Error('unsafe_request_accepted')
  }
})

Deno.test('safe record projection contains no provider response or content fields', () => {
  const safe = toSafeLedgerRecord({
    subject: 'stage-fixture-user-1',
    deletionEpoch: 1,
    kind: 'account',
    deviceIds: [],
    providerKeyIds: [],
    idempotencyKey: 'fixture-1',
    createdAt: '2026-08-16T05:00:00Z',
    auditActor: 'controlled_fixture',
    status: 'verified',
    verifiedAt: '2026-08-16T05:02:00Z',
  })
  if ('prompt' in safe || 'completion' in safe || 'plaintext' in safe || 'providerResponse' in safe) {
    throw new Error('unsafe_record_projection')
  }
})
