import { cleanupRun, makeFixturePlan, runFixture, STAGING_URL, type FixtureAdapter, type FixturePlan } from './authenticated-fixture.ts'

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
    recover(runId) {
      if (failure === 'recover') return Promise.reject(new Error('untrusted remote response'))
      const plan = makeFixturePlan()
      plan.runId = runId
      plan.users = [{ id: 'recovered-run', email: 'recovered@local.test', password: '' }]
      owners.set('recovered-run', runId)
      return Promise.resolve(plan)
    },
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

Deno.test('cleanupRun rejects malformed run IDs before recovery', async () => {
  const f = fake()
  const result = await cleanupRun('not-a-uuid', f.adapter)
  assert(!result.ok && result.stage === 'run-id' && f.calls() === 0)
  assert(f.owners.has('other-session'))
})

Deno.test('cleanupRun removes only recovered run resources', async () => {
  const f = fake()
  const runId = '00000000-0000-4000-8000-000000000999'
  const result = await cleanupRun(runId, f.adapter)
  assert(result.ok && result.cleanup === 'passed')
  assert(f.deleted.length === 1 && f.deleted[0] === 'recovered-run')
  assert(f.owners.has('other-session'))
})

Deno.test('cleanupRun reports recovery failure without deleting another run', async () => {
  const f = fake('recover')
  const result = await cleanupRun('00000000-0000-4000-8000-000000000999', f.adapter)
  assert(!result.ok && result.stage === 'recovery' && f.deleted.length === 0)
  assert(f.owners.has('other-session'))
})
