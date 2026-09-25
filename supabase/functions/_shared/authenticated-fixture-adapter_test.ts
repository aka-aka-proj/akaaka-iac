import { createAdapter } from '../testing/authenticated-test-agent.ts'
import { runFixture, STAGING_URL } from './authenticated-fixture.ts'

function assert(value: unknown, message = 'assertion failed'): asserts value { if (!value) throw new Error(message) }

for (const point of ['profile', 'login']) {
  Deno.test(`Supabase adapter cleans only current UUID after ${point} failure without exposing response`, async () => {
    const users = new Map<string, Record<string, unknown>>([['other-session', { id: 'other-session' }]])
    const deletes: string[] = []
    const requests: string[] = []
    const transport: typeof fetch = (input, init) => {
      const url = new URL(String(input))
      const path = url.pathname
      const method = init?.method ?? 'GET'
      requests.push(`${method} ${path}${url.search}`)
      const json = (body: unknown, status = 200) => Promise.resolve(new Response(JSON.stringify(body), {
        status, headers: { 'Content-Type': 'application/json' },
      }))
      if (path === '/auth/v1/admin/users' && method === 'POST') {
        const body = JSON.parse(String(init?.body))
        assert(body.id && body.app_metadata.fixture_run_id && body.password.length > 32)
        users.set(body.id, body)
        return json(body)
      }
      if (path.startsWith('/auth/v1/admin/users/')) {
        const id = path.split('/').at(-1)!
        if (method === 'DELETE') { deletes.push(id); users.delete(id); return json({}) }
        return users.has(id) ? json(users.get(id)) : json({ msg: 'User not found', error_code: 'user_not_found' }, 404)
      }
      if (path === '/auth/v1/token') return json({ msg: 'password=TOP_SECRET', error_code: 'invalid_credentials' }, 400)
      if (path === '/rest/v1/profiles' && method === 'POST') {
        return point === 'profile' ? json({ message: 'JWT=TOP_SECRET', code: '23514' }, 400) : json(null, 201)
      }
      if (method === 'DELETE') {
        assert(url.search.includes('id=') && !url.search.includes('other-session'))
        return json([])
      }
      if (path.startsWith('/rest/v1/')) return json([])
      throw new Error('unexpected request')
    }
    const result = await runFixture(STAGING_URL, createAdapter(STAGING_URL, 'service-secret', 'anon-secret', transport))
    assert(!result.ok && result.cleanup === 'passed')
    assert(result.stage === (point === 'profile' ? 'create-profile' : 'login'))
    assert(users.size === 1 && users.has('other-session') && deletes.length === 1)
    assert(!JSON.stringify(result).includes('TOP_SECRET'))
    assert(!requests.some((r) => r.startsWith('GET /auth/v1/admin/users?')))
  })
}

function recoveryTransport(foreignSeries = false): typeof fetch {
  return (input, init) => {
    const url = new URL(String(input))
    const json = (body: unknown, status = 200) => Promise.resolve(new Response(JSON.stringify(body), {
      status, headers: { 'Content-Type': 'application/json' },
    }))
    if (url.pathname === '/auth/v1/admin/users') {
      assert(url.searchParams.get('page') === '1')
      return json({ users: [
        { id: 'host', email: 'iac.patrol.test.host@example.com', app_metadata: { fixture_run_id: '00000000-0000-4000-8000-000000000999' } },
        { id: 'member', email: 'iac.patrol.test.member@example.com', app_metadata: { fixture_run_id: '00000000-0000-4000-8000-000000000999' } },
        { id: 'other', email: 'iac.patrol.test.other@example.com', app_metadata: { fixture_run_id: '00000000-0000-4000-8000-000000000998' } },
      ] })
    }
    if (url.pathname === '/rest/v1/event_series') {
      assert(url.searchParams.get('title') === 'eq.Fixture 00000000-0000-4000-8000-000000000999')
      return json([{ id: 'series-1', creator_id: foreignSeries ? 'other' : 'host' }])
    }
    if (url.pathname === '/rest/v1/events') {
      assert(url.searchParams.get('creator_id')?.includes('host'))
      assert(url.searchParams.get('title') === 'like.Fixture 00000000-0000-4000-8000-000000000999 %')
      return json([{ id: 'event-1', creator_id: 'host' }])
    }
    throw new Error(`unexpected ${init?.method ?? 'GET'} ${url.pathname}`)
  }
}

Deno.test('Supabase adapter recovery scopes to matching metadata and fixture tags', async () => {
  const adapter = createAdapter(STAGING_URL, 'service-secret', 'anon-secret', recoveryTransport())
  const plan = await adapter.recover('00000000-0000-4000-8000-000000000999')
  assert(plan.users.map((user) => user.id).join(',') === 'host,member')
  assert(plan.seriesIds.join(',') === 'series-1' && plan.eventIds.join(',') === 'event-1')
})

Deno.test('Supabase adapter recovery rejects a fixture tag owned by another run', async () => {
  const adapter = createAdapter(STAGING_URL, 'service-secret', 'anon-secret', recoveryTransport(true))
  let rejected = false
  try { await adapter.recover('00000000-0000-4000-8000-000000000999') } catch { rejected = true }
  assert(rejected)
})

for (const [status, expected] of [[400, 'create-user-http-400-code-unsafe_detail'], [429, 'create-user-http-429-code-unsafe_detail'], [503, 'create-user-http-503-code-unsafe_detail'], [0, 'create-user-unknown']]) {
  Deno.test(`Supabase adapter reports a safe create-user failure stage for ${status || 'missing'} status`, async () => {
    const transport: typeof fetch = (input, init) => {
      const url = new URL(String(input))
      if (url.pathname === '/auth/v1/admin/users' && init?.method === 'POST') {
        if (status === 0) return Promise.reject(new Error('password=TOP_SECRET'))
        const responseStatus = Number(status) || 500
        return Promise.resolve(new Response(JSON.stringify({ message: 'password=TOP_SECRET', code: 'unsafe_detail' }), {
          status: responseStatus, headers: { 'Content-Type': 'application/json' },
        }))
      }
      if (url.pathname.startsWith('/auth/v1/admin/users/')) {
        return Promise.resolve(new Response(JSON.stringify({ msg: 'User not found' }), { status: 404 }))
      }
      if (init?.method === 'DELETE') return Promise.resolve(new Response('[]', { status: 200 }))
      if (url.pathname.startsWith('/rest/v1/')) return Promise.resolve(new Response('[]', { status: 200 }))
      throw new Error(`unexpected ${init?.method ?? 'GET'} ${url.pathname}`)
    }
    const result = await runFixture(STAGING_URL, createAdapter(STAGING_URL, 'service-secret', 'anon-secret', transport))
    assert(!result.ok && result.stage === expected && result.cleanup === 'passed', JSON.stringify(result))
    assert(!JSON.stringify(result).includes('TOP_SECRET'))
    assert(!JSON.stringify(result).includes('password='))
  })
}
