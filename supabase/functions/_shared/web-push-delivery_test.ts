import {
  buildMinimalPushPayload,
  classifyProviderResponse,
  createDeliveryIdempotencyKey,
  createSyntheticDeliveryRecord,
  applySyntheticOutcome,
  claimSyntheticDelivery,
  deliverSyntheticOnce,
  deleteSyntheticSubscription,
  moveSyntheticSubscriptionOwnership,
  replaySyntheticDelivery,
  retryDelayMs,
} from './web-push-delivery.ts'
import type { ProviderOutcome } from './web-push-delivery.ts'

const notificationId = '00000000-0000-4000-8000-000000000001'
const eventId = '00000000-0000-4000-8000-000000000002'
const profileId = '00000000-0000-4000-8000-000000000003'

Deno.test('payload allowlist maps all notification types without private content', () => {
  const event = buildMinimalPushPayload({ notificationId, notificationType: 'new_event', eventId })
  if (JSON.stringify(event) !== JSON.stringify({
    notification_id: notificationId,
    notification_type: 'new_event',
    target: { kind: 'event', id: eventId },
  })) throw new Error('unexpected event payload')

  const follow = buildMinimalPushPayload({ notificationId, notificationType: 'new_follow', actorProfileId: profileId })
  if (follow.target.kind !== 'profile' || follow.target.id !== profileId) throw new Error('unexpected follow payload')

  const announcement = buildMinimalPushPayload({ notificationId, notificationType: 'event_announcement', eventId })
  if (announcement.target.kind !== 'event' || announcement.target.id !== eventId) throw new Error('unexpected announcement payload')

  for (const notificationType of ['new_issue', 'venue_application'] as const) {
    const payload = buildMinimalPushPayload({ notificationId, notificationType })
    if (payload.target.kind !== 'notifications' || 'id' in payload.target) throw new Error('unexpected private notification target')
  }
})

Deno.test('payload rejects invalid or missing target identifiers', () => {
  try {
    buildMinimalPushPayload({ notificationId, notificationType: 'new_event' })
    throw new Error('expected missing event id failure')
  } catch (error) {
    if (!(error instanceof Error) || error.message !== 'invalid_event_id') throw error
  }
})

Deno.test('idempotency key is stable and changes per subscription', async () => {
  const first = await createDeliveryIdempotencyKey(notificationId, profileId)
  const repeat = await createDeliveryIdempotencyKey(notificationId, profileId)
  const other = await createDeliveryIdempotencyKey(notificationId, eventId)
  if (first !== repeat || first === other || first.length !== 64) throw new Error('idempotency key contract failed')
})

Deno.test('provider failures are classified without response-body handling', () => {
  for (const status of [200, 204]) if (classifyProviderResponse(status) !== 'success') throw new Error('expected success')
  for (const status of [408, 425, 429, 500, 503]) if (classifyProviderResponse(status) !== 'retryable') throw new Error('expected retryable')
  for (const status of [404, 410]) if (classifyProviderResponse(status) !== 'endpoint_invalid') throw new Error('expected invalid endpoint')
  if (classifyProviderResponse(400) !== 'permanent_failure') throw new Error('expected permanent failure')
})

Deno.test('retry backoff is bounded', () => {
  if (retryDelayMs(1) !== 1_000 || retryDelayMs(3) !== 4_000 || retryDelayMs(10) !== 60_000) {
    throw new Error('unexpected retry delay')
  }
})

Deno.test('synthetic delivery is idempotent across duplicate claims', async () => {
  const record = await createSyntheticDeliveryRecord(notificationId, profileId)
  const claimed = claimSyntheticDelivery(record)
  const duplicateClaim = claimSyntheticDelivery(claimed)
  const sent = applySyntheticOutcome(duplicateClaim, 'success')
  const repeated = applySyntheticOutcome(sent, 'success')
  if (repeated.status !== 'sent' || repeated.attempts !== 1 || repeated.idempotencyKey !== record.idempotencyKey) {
    throw new Error('duplicate delivery changed terminal state')
  }
})

Deno.test('synthetic timeout retries then dead-letters and can replay', async () => {
  let record = await createSyntheticDeliveryRecord(notificationId, profileId)
  record = claimSyntheticDelivery(record)
  record = applySyntheticOutcome(record, 'retryable')
  record = claimSyntheticDelivery(record)
  record = applySyntheticOutcome(record, 'retryable')
  record = claimSyntheticDelivery(record)
  record = applySyntheticOutcome(record, 'retryable')
  if (record.status !== 'dead_letter' || record.attempts !== 3) throw new Error('expected dead letter')
  record = replaySyntheticDelivery(record)
  if (record.status !== 'pending' || record.idempotencyKey.length !== 64) throw new Error('expected replayable dead letter')
})

Deno.test('404/410 invalidates endpoint and deletion prevents replay', async () => {
  let record = await createSyntheticDeliveryRecord(notificationId, profileId)
  record = applySyntheticOutcome(claimSyntheticDelivery(record), 'endpoint_invalid')
  if (record.status !== 'endpoint_invalid' || record.subscriptionActive) throw new Error('expected endpoint cleanup')
  if (replaySyntheticDelivery(record).status !== 'endpoint_invalid') throw new Error('invalid endpoint was replayed')

  let deadLetter = await createSyntheticDeliveryRecord(notificationId, eventId)
  deadLetter = applySyntheticOutcome(claimSyntheticDelivery(deadLetter), 'permanent_failure')
  deadLetter = deleteSyntheticSubscription(deadLetter)
  if (replaySyntheticDelivery(deadLetter).status !== 'dead_letter') throw new Error('deleted subscription was replayed')
})

Deno.test('ownership handover after claim fences the provider call to zero side effects', async () => {
  let providerCalls: number = 0
  const send = (): ProviderOutcome => {
    providerCalls += 1
    return 'success'
  }

  const claimed = claimSyntheticDelivery(await createSyntheticDeliveryRecord(notificationId, profileId))
  const fenced = deliverSyntheticOnce(moveSyntheticSubscriptionOwnership(claimed), send)
  if (providerCalls !== 0) throw new Error('fenced handover must not reach the provider')
  if (fenced.record.status !== 'cancelled') throw new Error('expected fenced terminal cancellation')
  if (applySyntheticOutcome(fenced.record, 'success').status !== 'cancelled') {
    throw new Error('cancelled must be terminal against provider outcomes')
  }
  if (replaySyntheticDelivery(fenced.record).status !== 'cancelled') throw new Error('cancelled must not replay')
  if (claimSyntheticDelivery(fenced.record).status !== 'cancelled') throw new Error('cancelled must not re-claim')

  const control = deliverSyntheticOnce(
    claimSyntheticDelivery(await createSyntheticDeliveryRecord(eventId, profileId)),
    send,
  )
  if (providerCalls !== 1) throw new Error('clean path must call the provider exactly once')
  if (control.record.status !== 'sent') throw new Error('control path must deliver')
})
