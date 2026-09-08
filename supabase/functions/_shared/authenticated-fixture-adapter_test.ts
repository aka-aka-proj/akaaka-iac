import { createAdapter } from '../testing/authenticated-test-agent.ts'
import { runFixture, STAGING_URL } from './authenticated-fixture.ts'

function assert(value: unknown): asserts value { if (!value) throw new Error('assertion failed') }

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
