import { createClient } from '@supabase/supabase-js'
import { cleanupRun, FixtureFailure, runFixture, STAGING_URL, type FixtureAdapter, type FixturePlan } from '../_shared/authenticated-fixture.ts'

const options = { auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false } }

function requireValue(value: unknown, stage: string): asserts value {
  if (!value) throw new FixtureFailure(stage)
}

function safeHttpFailureStage(operation: string, error: unknown): string {
  const status = error && typeof error === 'object' && 'status' in error
    ? (error as { status?: unknown }).status
    : undefined
  return typeof status === 'number' && Number.isInteger(status) && status >= 400 && status <= 599
    ? `${operation}-http-${status}`
    : `${operation}-unknown`
}

export function createAdapter(url: string, serviceKey: string, anonKey: string, transport: typeof fetch = fetch): FixtureAdapter {
  requireValue(url === STAGING_URL, 'environment')
  const boundedFetch: typeof fetch = (input, init) => transport(input, { ...init, signal: AbortSignal.timeout(20000) })
  const admin = createClient(url, serviceKey, { ...options, global: { fetch: boundedFetch } })
  const client = (token: string) => createClient(url, anonKey, {
    ...options, global: { fetch: boundedFetch, headers: { Authorization: `Bearer ${token}` } },
  })
  async function notifications(token: string, series: string, expected: number) {
    const result = await client(token).from('notifications').select('id')
      .eq('event_series_id', series).eq('notification_type', 'event_series_registration')
    requireValue(!result.error && result.data?.length === expected, 'notification-count')
  }
  async function scenario(plan: FixturePlan, sessions: string[]) {
    const [host, member] = plan.users
    const [hostToken, memberToken] = sessions
    const [seriesId, transitionId] = plan.seriesIds
    let result = await admin.from('event_series').insert(plan.seriesIds.map((id) => ({
      id, creator_id: host.id, title: `Fixture ${plan.runId}`, lifecycle_status: 'draft',
    })))
    requireValue(!result.error, 'seed-series')
    result = await admin.from('events').insert(plan.eventIds.map((id, i) => ({
      id, creator_id: host.id, title: `Fixture ${plan.runId} ${i}`, event_type: 'workshop',
      start_time: new Date(Date.now() + (7 + i) * 86400000).toISOString(),
      lifecycle_status: 'draft', publication_status: 'closed',
      visibility_settings: { type: 'public' }, max_capacity: 10,
    })))
    requireValue(!result.error, 'seed-events')
    result = await admin.from('event_series_membership').insert(plan.eventIds.map((id, i) => ({
      series_id: plan.seriesIds[Math.floor(i / 2)], event_id: id, position: i % 2 + 1,
    })))
    requireValue(!result.error, 'seed-membership')
    for (const id of plan.seriesIds) {
      const published = await client(hostToken).functions.invoke('publish-event-series', { body: { series_id: id } })
      requireValue(!published.error && published.data?.success === true, 'publish-series')
    }

    const register = await client(memberToken).functions.invoke('register-for-event-series', { body: { series_id: seriesId } })
    requireValue(!register.error && register.data?.success === true && register.data?.event_registration_count === 2, 'register')
    await notifications(hostToken, seriesId, 1)
    await notifications(memberToken, seriesId, 0)
    const duplicate = await client(memberToken).functions.invoke('register-for-event-series', { body: { series_id: seriesId } })
    requireValue(duplicate.error?.context instanceof Response && duplicate.error.context.status === 400, 'duplicate-status')
    const duplicateBody = await duplicate.error.context.json()
    requireValue(duplicateBody.error?.code === 'duplicate_registration', 'duplicate-code')
    await notifications(hostToken, seriesId, 1)

    result = await admin.from('event_series_registrations').insert({
      series_id: transitionId, profile_id: member.id, status: 'pending', whole_series_registration: false,
    })
    requireValue(!result.error, 'seed-pending')
    await notifications(hostToken, transitionId, 0)
    for (let i = 0; i < 2; i++) {
      result = await admin.from('event_series_registrations').update({ status: 'approved' })
        .eq('series_id', transitionId).eq('profile_id', member.id)
      requireValue(!result.error, 'approve-transition')
      await notifications(hostToken, transitionId, 1)
    }
    await notifications(memberToken, transitionId, 0)
    return ['authenticated-series-registration', 'host-notification-once', 'nonrecipient-denied',
      'duplicate-registration-denied', 'service-fixture-pending-silent', 'service-fixture-approval-once']
  }

  return {
    async provision(user, runId) {
      let created
      try {
        created = await admin.auth.admin.createUser({
          id: user.id, email: user.email, password: user.password, email_confirm: true,
          app_metadata: { fixture_run_id: runId },
        })
      } catch {
        throw new FixtureFailure('create-user-unknown')
      }
      requireValue(!created.error && created.data.user?.id === user.id,
        safeHttpFailureStage('create-user', created.error))
      const profile = await admin.from('profiles').upsert({
        id: user.id, display_name: 'Synthetic fixture', role_status: 'general', reputation_score: 0,
        external_social_links: [{ url: 'https://x.com/fixture' }],
      })
      requireValue(!profile.error, 'create-profile')
    },
    async login(user) {
      const auth = createClient(url, anonKey, { ...options, global: { fetch: boundedFetch } })
      const result = await auth.auth.signInWithPassword({ email: user.email, password: user.password })
      requireValue(!result.error && result.data.user?.id === user.id && result.data.session, 'login')
      const assurance = await auth.auth.mfa.getAuthenticatorAssuranceLevel()
      requireValue(!assurance.error && assurance.data?.currentLevel === 'aal1', 'aal')
      return result.data.session.access_token
    },
    scenario,
    async owner(id) {
      const result = await admin.auth.admin.getUserById(id)
      if (result.error?.status === 404) return null
      requireValue(!result.error && result.data.user, 'owner-query')
      return result.data.user.app_metadata.fixture_run_id ?? 'unowned'
    },
    async revoke(token) {
      const result = await admin.auth.admin.signOut(token, 'global')
      requireValue(!result.error, 'revoke-session')
    },
    async cleanData(plan) {
      const host = plan.users[0].id
      // Only known fixture IDs are removed. Unknown foreign-key dependencies fail closed.
      if (plan.seriesIds.length > 0) {
        const series = await admin.from('event_series').delete().in('id', plan.seriesIds).eq('creator_id', host)
        requireValue(!series.error, 'cleanup-series')
        const remainingSeries = await admin.from('event_series').select('id').in('id', plan.seriesIds)
        requireValue(!remainingSeries.error && remainingSeries.data?.length === 0, 'cleanup-series-verification')
      }
      if (plan.eventIds.length > 0) {
        const events = await admin.from('events').delete().in('id', plan.eventIds).eq('creator_id', host)
        requireValue(!events.error, 'cleanup-events')
        const remainingEvents = await admin.from('events').select('id').in('id', plan.eventIds)
        requireValue(!remainingEvents.error && remainingEvents.data?.length === 0, 'cleanup-events-verification')
      }
    },
    async removeUser(id) {
      const profile = await admin.from('profiles').delete().eq('id', id)
      requireValue(!profile.error, 'cleanup-profile')
      const auth = await admin.auth.admin.deleteUser(id)
      requireValue(!auth.error, 'cleanup-auth')
      const remaining = await admin.auth.admin.getUserById(id)
      requireValue(remaining.error?.status === 404, 'cleanup-auth-verification')
    },
    async recover(runId) {
      const users: Array<{ id: string; email: string; password: string }> = []
      for (let page = 1; ; page++) {
        const result = await admin.auth.admin.listUsers({ page, perPage: 100 })
        requireValue(!result.error, 'recovery-users')
        users.push(...result.data.users
          .filter((user) => user.app_metadata.fixture_run_id === runId)
          .map((user) => ({ id: user.id, email: user.email ?? '', password: '' })))
        if (result.data.users.length < 100) break
      }
      requireValue(users.length > 0 && users.every((user) => user.email.startsWith('iac.patrol.test.')), 'recovery-scope')
      const userIds = users.map((user) => user.id)
      const series = await admin.from('event_series').select('id, creator_id')
        .eq('title', `Fixture ${runId}`)
      requireValue(!series.error && (series.data ?? []).every((row) => userIds.includes(row.creator_id)), 'recovery-series')
      const creators = [...new Set((series.data ?? []).map((row) => row.creator_id))]
      requireValue(creators.length <= 1, 'recovery-scope')
      const hostId = creators[0]
      const events = await admin.from('events').select('id, creator_id')
        .in('creator_id', userIds).like('title', `Fixture ${runId} %`)
      requireValue(!events.error && (events.data ?? []).every((row) => row.creator_id === hostId), 'recovery-events')
      const orderedUsers = hostId ? [
        ...users.filter((user) => user.id === hostId),
        ...users.filter((user) => user.id !== hostId),
      ] : users
      return {
        runId,
        users: orderedUsers,
        seriesIds: (series.data ?? []).map((row) => row.id),
        eventIds: (events.data ?? []).map((row) => row.id),
      }
    },
  }
}

async function main() {
  const command = Deno.args[0]
  requireValue(command === 'list' || command === 'verify-series-notification' || command === 'cleanup-run', 'command')
  const url = Deno.env.get('SUPABASE_URL')
  requireValue(url === STAGING_URL, 'environment')
  const serviceKey = Deno.env.get('SERVICE_ROLE_KEY')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  requireValue(serviceKey && anonKey, 'configuration')
  if (command === 'list') {
    const admin = createClient(url, serviceKey, options)
    let count = 0
    for (let page = 1; ; page++) {
      const result = await admin.auth.admin.listUsers({ page, perPage: 100 })
      requireValue(!result.error, 'list')
      count += result.data.users.filter((u) => u.email?.startsWith('iac.patrol.test.')).length
      if (result.data.users.length < 100) break
    }
    console.log(JSON.stringify({ count }))
    return
  }
  if (command === 'cleanup-run') {
    const result = await cleanupRun(Deno.args[1] ?? '', createAdapter(url, serviceKey, anonKey))
    console.log(JSON.stringify({ ...result, project: 'xdknuxdhyvjgwlcliyqx' }))
    if (!result.ok) Deno.exitCode = 1
    return
  }
  const result = await runFixture(url, createAdapter(url, serviceKey, anonKey),
    (runId) => console.log(JSON.stringify({ runId, stage: 'started' })))
  console.log(JSON.stringify({ ...result, project: 'xdknuxdhyvjgwlcliyqx', role: 'authenticated', aal: 'aal1' }))
  if (!result.ok) Deno.exitCode = 1
}

if (import.meta.main) {
  try { await main() } catch {
    console.error(JSON.stringify({ ok: false, stage: 'configuration-or-list' }))
    Deno.exitCode = 1
  }
}
