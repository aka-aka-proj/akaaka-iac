export type NotificationType =
  | 'new_event'
  | 'new_issue'
  | 'new_follow'
  | 'venue_application'
  | 'event_invitation'
  | 'event_announcement'

export interface NotificationDeliveryInput {
  notificationId: string
  notificationType: NotificationType
  eventId?: string | null
  actorProfileId?: string | null
  venueApplicationProfileId?: string | null
}

export interface MinimalPushPayload {
  notification_id: string
  notification_type: NotificationType
  target: { kind: 'event' | 'profile' | 'notifications'; id?: string }
}

export type ProviderOutcome = 'success' | 'retryable' | 'endpoint_invalid' | 'permanent_failure'

export type SyntheticDeliveryStatus = 'pending' | 'processing' | 'sent' | 'endpoint_invalid' | 'dead_letter'

export type SyntheticDeliveryLifecycleStatus = SyntheticDeliveryStatus | 'cancelled'

export interface SyntheticDeliveryRecord {
  idempotencyKey: string
  notificationId: string
  subscriptionId: string
  status: SyntheticDeliveryLifecycleStatus
  attempts: number
  subscriptionActive: boolean
  subscriptionOwnerGeneration: number
  claimedOwnerGeneration?: number
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

function requireUuid(value: string | null | undefined, field: string): string {
  if (!value || !UUID.test(value)) throw new Error(`invalid_${field}`)
  return value
}

export function buildMinimalPushPayload(input: NotificationDeliveryInput): MinimalPushPayload {
  const notificationId = requireUuid(input.notificationId, 'notification_id')

  switch (input.notificationType) {
    case 'new_event':
    case 'event_invitation':
    case 'event_announcement':
      return {
        notification_id: notificationId,
        notification_type: input.notificationType,
        target: { kind: 'event', id: requireUuid(input.eventId, 'event_id') },
      }
    case 'new_follow':
      return {
        notification_id: notificationId,
        notification_type: input.notificationType,
        target: { kind: 'profile', id: requireUuid(input.actorProfileId, 'actor_profile_id') },
      }
    case 'new_issue':
      return { notification_id: notificationId, notification_type: input.notificationType, target: { kind: 'notifications' } }
    case 'venue_application':
      return { notification_id: notificationId, notification_type: input.notificationType, target: { kind: 'notifications' } }
  }
}

export async function createDeliveryIdempotencyKey(notificationId: string, subscriptionId: string): Promise<string> {
  const input = new TextEncoder().encode(`${notificationId}:${subscriptionId}`)
  const digest = await crypto.subtle.digest('SHA-256', input)
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('')
}

export function classifyProviderResponse(status: number): ProviderOutcome {
  if (status >= 200 && status < 300) return 'success'
  if (status === 404 || status === 410) return 'endpoint_invalid'
  if (status === 408 || status === 425 || status === 429 || status >= 500) return 'retryable'
  return 'permanent_failure'
}

export function retryDelayMs(attempt: number, baseMs = 1_000, maxMs = 60_000): number {
  if (!Number.isInteger(attempt) || attempt < 1) throw new Error('invalid_attempt')
  if (!Number.isFinite(baseMs) || baseMs < 1 || !Number.isFinite(maxMs) || maxMs < baseMs) throw new Error('invalid_backoff')
  return Math.min(maxMs, baseMs * (2 ** (attempt - 1)))
}

export async function createSyntheticDeliveryRecord(
  notificationId: string,
  subscriptionId: string,
): Promise<SyntheticDeliveryRecord> {
  return {
    idempotencyKey: await createDeliveryIdempotencyKey(notificationId, subscriptionId),
    notificationId,
    subscriptionId,
    status: 'pending',
    attempts: 0,
    subscriptionActive: true,
    subscriptionOwnerGeneration: 0,
  }
}

export function claimSyntheticDelivery(record: SyntheticDeliveryRecord): SyntheticDeliveryRecord {
  if (record.status !== 'pending') return { ...record }
  return { ...record, status: 'processing', claimedOwnerGeneration: record.subscriptionOwnerGeneration }
}

export function moveSyntheticSubscriptionOwnership(record: SyntheticDeliveryRecord): SyntheticDeliveryRecord {
  return { ...record, subscriptionOwnerGeneration: record.subscriptionOwnerGeneration + 1 }
}

export function canSendToProvider(record: SyntheticDeliveryRecord): boolean {
  return (
    record.status === 'processing' &&
    record.subscriptionActive &&
    record.claimedOwnerGeneration === record.subscriptionOwnerGeneration
  )
}

export function fenceSyntheticDeliveryCancelled(record: SyntheticDeliveryRecord): SyntheticDeliveryRecord {
  if (record.status !== 'processing') return { ...record }
  return { ...record, status: 'cancelled' }
}

export function applySyntheticOutcome(
  record: SyntheticDeliveryRecord,
  outcome: ProviderOutcome,
  maxAttempts = 3,
): SyntheticDeliveryRecord {
  if (!Number.isInteger(maxAttempts) || maxAttempts < 1) throw new Error('invalid_max_attempts')
  if (
    record.status === 'sent' ||
    record.status === 'endpoint_invalid' ||
    record.status === 'dead_letter' ||
    record.status === 'cancelled'
  ) {
    return { ...record }
  }

  const attempts = record.attempts + 1
  if (outcome === 'success') return { ...record, status: 'sent', attempts }
  if (outcome === 'endpoint_invalid') return { ...record, status: 'endpoint_invalid', attempts, subscriptionActive: false }
  if (outcome === 'permanent_failure' || attempts >= maxAttempts) return { ...record, status: 'dead_letter', attempts }
  return { ...record, status: 'pending', attempts }
}

export function replaySyntheticDelivery(record: SyntheticDeliveryRecord): SyntheticDeliveryRecord {
  if (record.status !== 'dead_letter' || !record.subscriptionActive) return { ...record }
  return { ...record, status: 'pending' }
}

export function deleteSyntheticSubscription(record: SyntheticDeliveryRecord): SyntheticDeliveryRecord {
  return { ...record, subscriptionActive: false }
}
