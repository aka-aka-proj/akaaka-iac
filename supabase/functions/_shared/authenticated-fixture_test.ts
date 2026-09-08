import { makeFixturePlan, runFixture, STAGING_URL, type FixtureAdapter, type FixturePlan } from './authenticated-fixture.ts'

function assert(value: unknown, message = 'assertion failed'): asserts value {
  if (!value) throw new Error(message)
}

function fake(failure = '') {
  const owners = new Map<string, string>([['other-session', 'other-run']])
  const deleted: string[] = []
  let calls = 0
  const adapter: FixtureAdapter = {
    provision(user, runId) {
      calls++
      owners.set(user.id, failure === 'ownership' ? 'other-run' : runId)
      if (failure === 'provision') throw new Error(`SDK secret ${user.password}`)
      return Promise.resolve()
    },
    login() {
      if (failure === 'login') throw new Error('access_token=secret')
      return Promise.resolve('session-secret')
    },
    scenario() {
      if (failure === 'scenario') throw new Error('refresh_token=secret')
      return Promise.resolve(['authenticated-registration', 'approval-transition'])
    },
    owner(id) { return Promise.resolve(owners.get(id) ?? null) },
    revoke() { return failure === 'revoke' ? Promise.reject(new Error('token-secret')) : Promise.resolve() },
    cleanData() { return failure === 'cleanup' ? Promise.reject(new Error('secret data')) : Promise.resolve() },
    removeUser(id) { deleted.push(id); owners.delete(id); return Promise.resolve() },
  }
  return { adapter, owners, deleted, calls: () => calls }
}

Deno.test('fixture plans use unique run, identities and cryptographic passwords', () => {
  const a = makeFixturePlan(), b = makeFixturePlan()
  assert(a.runId !== b.runId)
  assert(new Set([...a.users, ...b.users].map((u) => u.password)).size === 4)
  assert(a.users.every((u) => u.password.length >= 32 && u.email.includes(a.runId)))
})

Deno.test('wrong project fails before any provisioning', async () => {
  const f = fake()
  const result = await runFixture('https://production.invalid', f.adapter)
  assert(!result.ok && f.calls() === 0)
})

for (const failure of ['', 'provision', 'login', 'scenario']) {
  Deno.test(`fixture cleanup isolates run after ${failure || 'success'}`, async () => {
    const f = fake(failure)
    const result = await runFixture(STAGING_URL, f.adapter)
    assert(result.ok === (failure === ''))
    assert(result.cleanup === 'passed')
    assert(f.owners.size === 1 && f.owners.has('other-session'))
    assert(!JSON.stringify(result).includes('secret'))
    assert(f.deleted.length === (failure === 'provision' || failure === 'login' ? 1 : 2))
  })
}

for (const failure of ['ownership', 'cleanup', 'revoke']) {
  Deno.test(`cleanup ${failure} cannot produce green evidence`, async () => {
    const f = fake(failure)
    const result = await runFixture(STAGING_URL, f.adapter)
    assert(!result.ok && result.cleanup === 'failed')
    assert(f.owners.has('other-session'))
    if (failure !== 'revoke') assert(f.deleted.length === 0)
    assert(!JSON.stringify(result).includes('secret'))
  })
}

Deno.test('all planned IDs remain available after a lost provisioning response', async () => {
  const f = fake('provision')
  let plan: FixturePlan | undefined
  const clean = f.adapter.cleanData
  f.adapter.cleanData = async (p) => { plan = p; await clean(p) }
  const result = await runFixture(STAGING_URL, f.adapter)
  assert(plan?.runId === result.runId)
  assert(plan?.eventIds.length === 4 && plan.seriesIds.length === 2)
  assert(result.cleanup === 'passed')
})
