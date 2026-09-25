export const STAGING_URL = 'https://xdknuxdhyvjgwlcliyqx.supabase.co'
export class FixtureFailure extends Error {}

export interface FixtureUser { id: string; email: string; password: string }
export interface FixturePlan {
  runId: string
  users: FixtureUser[]
  eventIds: string[]
  seriesIds: string[]
}
export interface FixtureAdapter {
  provision(user: FixtureUser, runId: string): Promise<void>
  login(user: FixtureUser): Promise<string>
  scenario(plan: FixturePlan, sessions: string[]): Promise<string[]>
  owner(id: string): Promise<string | null>
  revoke(session: string): Promise<void>
  cleanData(plan: FixturePlan): Promise<void>
  removeUser(id: string): Promise<void>
  recover(runId: string): Promise<FixturePlan>
}

export function makeFixturePlan(): FixturePlan {
  const runId = crypto.randomUUID()
  return {
    runId,
    users: ['host', 'member'].map((role) => ({
      id: crypto.randomUUID(),
      email: `iac.patrol.test.${runId}.${role}@example.com`,
      password: `Aa1!${crypto.randomUUID()}`,
    })),
    eventIds: Array.from({ length: 4 }, () => crypto.randomUUID()),
    seriesIds: [crypto.randomUUID(), crypto.randomUUID()],
  }
}

async function cleanFixture(adapter: FixtureAdapter, plan: FixturePlan) {
  // Check every planned identity, including ambiguous create responses, before deleting data.
  const existing: string[] = []
  for (const user of plan.users) {
    const owner = await adapter.owner(user.id)
    if (owner === null) continue
    if (owner !== plan.runId) throw new Error('ownership')
    existing.push(user.id)
  }
  await adapter.cleanData(plan)
  for (const id of existing) await adapter.removeUser(id)
}

function validRunId(runId: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(runId)
}

export async function cleanupRun(runId: string, adapter: FixtureAdapter) {
  if (!validRunId(runId)) return { ok: false, runId, stage: 'run-id', cleanup: 'not-needed' as const }
  try {
    const plan = await adapter.recover(runId)
    if (plan.runId !== runId || plan.users.length === 0) throw new FixtureFailure('recovery-scope')
    await cleanFixture(adapter, plan)
    return { ok: true, runId, stage: 'complete', cleanup: 'passed' as const }
  } catch (error) {
    return { ok: false, runId, stage: error instanceof FixtureFailure ? error.message : 'recovery', cleanup: 'failed' as const }
  }
}

export async function runFixture(url: string, adapter: FixtureAdapter, started: (runId: string) => void = () => {}) {
  const plan = makeFixturePlan()
  let stage = 'environment'
  let failure: string | null = null
  let cleanupFailure: string | null = null
  let cleanup: 'passed' | 'failed' | 'not-needed' = 'not-needed'
  let checks: string[] = []
  const sessions: string[] = []
  if (url !== STAGING_URL) return { ok: false, runId: plan.runId, stage, cleanup, checks }
  started(plan.runId)
  try {
    for (const user of plan.users) {
      stage = 'provision'
      await adapter.provision(user, plan.runId)
      stage = 'login'
      sessions.push(await adapter.login(user))
    }
    stage = 'scenario'
    checks = await adapter.scenario(plan, sessions)
  } catch (error) {
    failure = error instanceof FixtureFailure ? error.message : stage
  } finally {
    cleanup = 'passed'
    for (const session of sessions) {
      try { await adapter.revoke(session) } catch { cleanup = 'failed'; cleanupFailure = 'revoke-session' }
    }
    try {
      await cleanFixture(adapter, plan)
    } catch (error) {
      cleanup = 'failed'
      cleanupFailure = error instanceof FixtureFailure ? error.message : 'cleanup'
    }
  }
  return { ok: failure === null && cleanup === 'passed', runId: plan.runId,
    stage: failure ?? (cleanup === 'passed' ? 'complete' : 'cleanup'), cleanup, cleanupFailure, checks }
}
