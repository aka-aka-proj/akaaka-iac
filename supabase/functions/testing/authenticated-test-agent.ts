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
  if (!(typeof status === 'number' && Number.isInteger(status) && status >= 400 && status <= 599)) {
    return `${operation}-unknown`
  }
  const code = 'code' in (error as object) ? (error as { code?: unknown }).code : undefined
  const safeCode = typeof code === 'string' && /^[a-z0-9_]{1,64}$/.test(code) ? code : undefined
  return safeCode ? `${operation}-http-${status}-code-${safeCode}` : `${operation}-http-${status}`
}

export function createAdapter(url: string, serviceKey: string, anonKey: string, transport: typeof fetch = fetch): FixtureAdapter & { blocklistScenario(plan: FixturePlan, sessions: string[]): Promise<string[]>; recurrenceScenario(plan: FixturePlan, sessions: string[]): Promise<string[]> } {
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

  async function recurrenceScenario(plan: FixturePlan, sessions: string[]) {
    const [host] = plan.users
    const [hostToken] = sessions
    const offsetParent = plan.eventIds[0]
    const legacyParent = plan.eventIds[1]
    const base = new Date(Date.now() + 21 * 86400000)
    const legacyDeadline = new Date(base.getTime() - 3 * 86400000).toISOString()
    let result = await admin.from('events').insert([
      {
        id: offsetParent, creator_id: host.id, title: `Fixture ${plan.runId} recurrence offset`, event_type: 'workshop',
        start_time: base.toISOString(), registration_deadline: legacyDeadline, lifecycle_status: 'draft',
        publication_status: 'closed', visibility_settings: { type: 'public' }, max_capacity: 10,
      },
      {
        id: legacyParent, creator_id: host.id, title: `Fixture ${plan.runId} recurrence legacy`, event_type: 'workshop',
        start_time: base.toISOString(), registration_deadline: legacyDeadline, lifecycle_status: 'draft',
        publication_status: 'closed', visibility_settings: { type: 'public' }, max_capacity: 10,
      },
    ])
    requireValue(!result.error, 'recurrence-seed-parents')

    const offsetRule = { frequency: 'weekly', interval: 1, days: [base.toLocaleDateString('en-US', { weekday: 'short', timeZone: 'UTC' })], count: 2,
      timezone: 'UTC', registration_deadline_offset_minutes: 1440 }
    const offset = await client(hostToken).functions.invoke('create-recurring-events', {
      body: { parent_event_id: offsetParent, recurrence_rule: offsetRule, start_time: base.toISOString() },
    })
    requireValue(!offset.error && offset.data?.success === true && offset.data?.created_instance_count === 1, 'recurrence-offset-create')
    const offsetChildId = offset.data.instance_ids?.[1]
    requireValue(typeof offsetChildId === 'string', 'recurrence-offset-child')
    const offsetChild = await admin.from('events').select('start_time,registration_deadline').eq('id', offsetChildId).single()
    requireValue(!offsetChild.error && offsetChild.data?.registration_deadline &&
      new Date(offsetChild.data.start_time).getTime() - new Date(offsetChild.data.registration_deadline).getTime() === 1440 * 60000,
      'recurrence-offset-instance-deadline')
    plan.eventIds.push(offsetChildId)

    const legacyRule = { frequency: 'weekly', interval: 1, days: [base.toLocaleDateString('en-US', { weekday: 'short', timeZone: 'UTC' })], count: 2, timezone: 'UTC' }
    const legacy = await client(hostToken).functions.invoke('create-recurring-events', {
      body: { parent_event_id: legacyParent, recurrence_rule: legacyRule, start_time: base.toISOString() },
    })
    requireValue(!legacy.error && legacy.data?.success === true && legacy.data?.created_instance_count === 1, 'recurrence-legacy-create')
    const legacyChildId = legacy.data.instance_ids?.[1]
    requireValue(typeof legacyChildId === 'string', 'recurrence-legacy-child')
    const legacyChild = await admin.from('events').select('registration_deadline').eq('id', legacyChildId).single()
    requireValue(!legacyChild.error && legacyChild.data?.registration_deadline === legacyDeadline, 'recurrence-legacy-absolute-deadline')
    plan.eventIds.push(legacyChildId)

    const locked = await admin.from('events').update({ start_time: new Date(base.getTime() + 8 * 86400000).toISOString() }).eq('id', offsetChildId)
    requireValue(!!locked.error, 'recurrence-scheduling-lock-rejected')
    return ['recurrence-offset-instance-deadline', 'recurrence-legacy-absolute-deadline', 'recurrence-scheduling-lock-rejected']
  }

  async function blocklistScenario(plan: FixturePlan, sessions: string[]) {
    const [host, member] = plan.users
    const [, memberToken] = sessions
    const peer = { id: crypto.randomUUID(), email: `iac.patrol.test.${plan.runId}.peer@example.com`, password: `Aa1!${crypto.randomUUID()}` }
    await adapter.provision(peer, plan.runId)
    plan.users.push(peer)
    const eventId = plan.eventIds[0]
    let result = await admin.from('events').insert({
      id: eventId, creator_id: host.id, title: `Fixture ${plan.runId} blocklist`, event_type: 'workshop',
      start_time: new Date(Date.now() + 7 * 86400000).toISOString(), lifecycle_status: 'registration_open',
      publication_status: 'published', visibility_settings: { type: 'public' }, max_capacity: 10,
    })
    requireValue(!result.error, 'blocklist-seed-event')
    result = await admin.from('event_registrations').insert({ event_id: eventId, profile_id: peer.id, status: 'approved' })
    requireValue(!result.error, 'blocklist-seed-peer')
    result = await admin.from('blocks').insert({ blocker_id: member.id, blocked_id: peer.id })
    requireValue(!result.error, 'blocklist-seed-outgoing')

    const warning = await client(memberToken).functions.invoke('create-registration', { body: { event_id: eventId } })
    requireValue(warning.error?.context instanceof Response && warning.error.context.status === 409, 'blocklist-outgoing-conflict-409')
    const warningBody = await warning.error.context.json()
    requireValue(warningBody.error?.code === 'blocklist_confirmation_required', 'blocklist-outgoing-conflict-code')
    requireValue(typeof warningBody.error?.details?.warning_event_id === 'string', 'blocklist-outgoing-conflict-shape')

    const acknowledged = await client(memberToken).functions.invoke('create-registration', {
      body: { event_id: eventId, acknowledge_blocklist_conflict: true },
    })
    requireValue(!acknowledged.error && acknowledged.data?.success === true, 'blocklist-acknowledgement-success')

    // Acknowledgement is transaction/event scoped: a successful acknowledgement for one event
    // must never suppress a conflict warning for a different event.
    const scopedEventId = plan.eventIds[1]
    result = await admin.from('events').insert({
      id: scopedEventId, creator_id: host.id, title: `Fixture ${plan.runId} blocklist scoped`, event_type: 'workshop',
      start_time: new Date(Date.now() + 8 * 86400000).toISOString(), lifecycle_status: 'registration_open',
      publication_status: 'published', visibility_settings: { type: 'public' }, max_capacity: 10,
    })
    requireValue(!result.error, 'blocklist-scope-seed-event')
    result = await admin.from('event_registrations').insert({ event_id: scopedEventId, profile_id: peer.id, status: 'approved' })
    requireValue(!result.error, 'blocklist-scope-seed-peer')
    const scoped = await client(memberToken).functions.invoke('create-registration', { body: { event_id: scopedEventId } })
    requireValue(scoped.error?.context instanceof Response && scoped.error.context.status === 409, 'blocklist-acknowledgement-event-scoped')

    result = await admin.from('event_registrations').delete().eq('event_id', eventId).eq('profile_id', member.id)
    requireValue(!result.error, 'blocklist-reset-registration')

    // Only active/co-present registration states contribute to the warning. Exercise the
    // canonical status matrix against the same actor pair to keep directionality constant.
    for (const [status, conflicts] of [
      ['pending', true],
      ['approved', true],
      ['waitlisted', true],
      ['cancellation_pending', true],
      ['cancellation_rejected', true],
      ['rejected', false],
      ['cancelled', false],
    ] as const) {
      result = await admin.from('event_registrations').update({ status }).eq('event_id', eventId).eq('profile_id', peer.id)
      requireValue(!result.error, `blocklist-status-${status}-seed`)
      const attempt = await client(memberToken).functions.invoke('create-registration', { body: { event_id: eventId } })
      const warned = attempt.error?.context instanceof Response && attempt.error.context.status === 409
      requireValue(conflicts ? warned : (!attempt.error && attempt.data?.success === true), `blocklist-status-${status}-${conflicts ? 'conflict' : 'ignored'}`)
      if (!conflicts) {
        result = await admin.from('event_registrations').delete().eq('event_id', eventId).eq('profile_id', member.id)
        requireValue(!result.error, `blocklist-status-${status}-reset`)
      }
    }

    result = await admin.from('blocks').delete().eq('blocker_id', member.id).eq('blocked_id', peer.id)
    requireValue(!result.error, 'blocklist-reset-outgoing')
    result = await admin.from('blocks').insert({ blocker_id: peer.id, blocked_id: member.id })
    requireValue(!result.error, 'blocklist-seed-reverse')
    const reverse = await client(memberToken).functions.invoke('create-registration', { body: { event_id: eventId } })
    requireValue(!reverse.error && reverse.data?.success === true, 'blocklist-reverse-hidden')
    return ['blocklist-outgoing-conflict-409', 'blocklist-outgoing-conflict-code', 'blocklist-outgoing-conflict-shape',
      'blocklist-acknowledgement-success', 'blocklist-acknowledgement-event-scoped',
      'blocklist-status-pending-conflict', 'blocklist-status-approved-conflict', 'blocklist-status-waitlisted-conflict',
      'blocklist-status-cancellation_pending-conflict', 'blocklist-status-cancellation_rejected-conflict',
      'blocklist-status-rejected-ignored', 'blocklist-status-cancelled-ignored', 'blocklist-reverse-hidden']
  }

  const adapter: FixtureAdapter & { blocklistScenario(plan: FixturePlan, sessions: string[]): Promise<string[]> } = {
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
    blocklistScenario,
    recurrenceScenario,
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
      if (plan.users.length > 2) {
        const fixtureUserIds = plan.users.map((user) => user.id)
        const blocks = await admin.from('blocks').delete().or(`blocker_id.in.(${fixtureUserIds.join(',')}),blocked_id.in.(${fixtureUserIds.join(',')})`)
        requireValue(!blocks.error, 'cleanup-blocks')
      }
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
  return adapter
}

async function main() {
  const command = Deno.args[0]
  requireValue(command === 'list' || command === 'verify-series-notification' || command === 'verify-blocklist-conflict' || command === 'verify-recurrence-behavior' || command === 'cleanup-run', 'command')
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
  const adapter = createAdapter(url, serviceKey, anonKey)
  if (command === 'verify-blocklist-conflict') adapter.scenario = adapter.blocklistScenario
  if (command === 'verify-recurrence-behavior') adapter.scenario = adapter.recurrenceScenario
  const result = await runFixture(url, adapter,
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
