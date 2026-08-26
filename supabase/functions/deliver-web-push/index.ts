import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import webpush from "web-push";
import {
  buildMinimalPushPayload,
  classifyProviderResponse,
  retryDelayMs,
} from "../_shared/web-push-delivery.ts";

const MAX_ATTEMPTS = 3;
const DEFAULT_LIMIT = 25;
const MAX_LIMIT = 100;

type DeliveryRow = {
  delivery_id: string;
  notification_id: string;
  push_subscription_id: string;
  attempts: number;
  // Lease identity returned by claim_notification_push_deliveries: both
  // fields participate in every write-back fence (api/003 §Delivery and
  // concurrency). claim always stamps claimed_at.
  claimed_at: string;
  // Ownership generation of the subscription at claim time; compared against
  // a fresh read just before sending and inside settle_push_delivery.
  owner_generation: number;
  notification_type:
    | "new_event"
    | "new_issue"
    | "new_follow"
    | "venue_application"
    | "event_invitation"
    | "event_announcement"
    | "event_series_registration";
  event_id: string | null;
  actor_profile_id: string | null;
  venue_application_profile_id: string | null;
  endpoint: string;
  p256dh: string;
  auth: string;
};

type DeliverySummary = {
  claimed: number;
  sent: number;
  retryable: number;
  endpoint_invalid: number;
  cancelled: number;
  dead_letter: number;
  skipped: number;
};

type AdminClient = SupabaseClient;

function json(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

function constantTimeEqual(left: string, right: string): boolean {
  const leftBytes = new TextEncoder().encode(left);
  const rightBytes = new TextEncoder().encode(right);
  let difference = leftBytes.length ^ rightBytes.length;
  const length = Math.max(leftBytes.length, rightBytes.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (leftBytes[index] ?? 0) ^ (rightBytes[index] ?? 0);
  }
  return difference === 0;
}

function providerStatus(error: unknown): number | undefined {
  if (!error || typeof error !== "object") return undefined;
  const value = (error as { statusCode?: unknown }).statusCode;
  return typeof value === "number" && Number.isInteger(value)
    ? value
    : undefined;
}

function stableErrorCode(status: number | undefined): string {
  return status === undefined
    ? "provider_network_error"
    : `provider_http_${status}`;
}

function parseLimit(value: unknown): number {
  if (value === undefined) return DEFAULT_LIMIT;
  if (
    typeof value !== "number" || !Number.isInteger(value) || value < 1 ||
    value > MAX_LIMIT
  ) {
    throw new Error("invalid_delivery_limit");
  }
  return value;
}

function parseNow(value: unknown): string {
  if (value === undefined) return new Date().toISOString();
  if (typeof value !== "string" || Number.isNaN(Date.parse(value))) {
    throw new Error("invalid_delivery_now");
  }
  return new Date(value).toISOString();
}

// Lease-fenced direct update for pre-send transitions only. The fence is the
// four-field identity from api/003 (id, status='processing', claimed_at,
// attempts); ownership generation deliberately does not apply here because
// these paths run while the subscription may legitimately be absent — that is
// often the very reason we are cancelling.
async function fenceUpdate(
  admin: AdminClient,
  row: DeliveryRow,
  patch: Record<string, unknown>,
): Promise<boolean> {
  const { count, error } = await admin
    .from("notification_push_deliveries")
    .update({ ...patch, updated_at: new Date().toISOString() }, {
      count: "exact",
    })
    .eq("id", row.delivery_id)
    .eq("status", "processing")
    .eq("claimed_at", row.claimed_at)
    .eq("attempts", row.attempts);
  if (error) throw new Error("delivery_state_update_failed");
  return (count ?? 0) > 0;
}

// Post-provider write-backs go through settle_push_delivery so lease fencing
// and ownership-generation fencing are enforced atomically in SQL. A false
// result means this worker lost the race (lease stolen or endpoint moved):
// callers must surface that as skipped work, never as a classification.
async function settleDelivery(
  admin: AdminClient,
  row: DeliveryRow,
  status: "sent" | "pending" | "dead_letter" | "endpoint_invalid",
  errorCode: string | null,
  sentAt?: string,
  availableAt?: string,
): Promise<boolean> {
  const { data, error } = await admin.rpc("settle_push_delivery", {
    p_delivery_id: row.delivery_id,
    p_claimed_at: row.claimed_at,
    p_attempts: row.attempts,
    p_owner_generation: row.owner_generation,
    p_subscription_id: row.push_subscription_id,
    p_status: status,
    p_error_code: errorCode,
    p_sent_at: sentAt ?? null,
    p_available_at: availableAt ?? null,
  });
  if (error) throw new Error("delivery_settle_failed");
  return data === true;
}

type DeliveryOutcome = keyof Omit<
  DeliverySummary,
  "claimed" | "skipped"
>;

async function processDelivery(
  admin: AdminClient,
  row: DeliveryRow,
  recipientProfileId: string,
  now: string,
): Promise<DeliveryOutcome | "skipped"> {
  let payload: ReturnType<typeof buildMinimalPushPayload>;
  try {
    payload = buildMinimalPushPayload({
      notificationId: row.notification_id,
      notificationType: row.notification_type,
      eventId: row.event_id,
      actorProfileId: row.actor_profile_id,
      venueApplicationProfileId: row.venue_application_profile_id,
    });
  } catch {
    // Poison message: no provider side effect happened, so the plain lease
    // fence is enough to terminalize it.
    const fenced = await fenceUpdate(admin, row, {
      status: "dead_letter",
      last_error_code: "invalid_notification_target",
    });
    return fenced ? "dead_letter" : "skipped";
  }

  // Last-moment ownership re-read (api/003): between claim and send the
  // subscription can disappear (scheduled cleanup, fan-out revocation) or
  // move to another profile via subscribe_push_subscription. The row lock
  // taken by the move transaction serializes with nothing here — the data-row
  // lock is released at commit — so generation fencing carries the guarantee
  // across the validate→send boundary. Delivering anyway would leak the
  // previous profile's notification to a device now controlled by someone
  // else, so abort without calling the provider and fence the job to the
  // terminal `cancelled` state.
  const { data: subscription, error: subscriptionError } = await admin
    .from("push_subscriptions")
    .select("profile_id, owner_generation")
    .eq("id", row.push_subscription_id)
    .maybeSingle();
  if (subscriptionError) throw new Error("subscription_validation_failed");

  if (
    subscription === null ||
    subscription.owner_generation !== row.owner_generation ||
    subscription.profile_id !== recipientProfileId
  ) {
    const fenced = await fenceUpdate(admin, row, {
      status: "cancelled",
      last_error_code: "subscription_unavailable",
    });
    return fenced ? "cancelled" : "skipped";
  }

  let status: number | undefined;
  try {
    const response = await webpush.sendNotification(
      {
        endpoint: row.endpoint,
        keys: { p256dh: row.p256dh, auth: row.auth },
      },
      JSON.stringify(payload),
      { TTL: 60 },
    );
    status = response.statusCode;
  } catch (error) {
    status = providerStatus(error);
  }

  const outcome = classifyProviderResponse(status ?? 503);
  if (outcome === "success") {
    const settled = await settleDelivery(
      admin,
      row,
      "sent",
      null,
      now,
    );
    return settled ? "sent" : "skipped";
  }

  const errorCode = stableErrorCode(status);
  if (outcome === "endpoint_invalid") {
    // Atomic in SQL: fenced transition to `endpoint_invalid` first, then the
    // subscription delete in the same transaction. A stale worker gets false
    // back and leaves the subscription alone entirely.
    try {
      const settled = await settleDelivery(
        admin,
        row,
        "endpoint_invalid",
        errorCode,
      );
      return settled ? "endpoint_invalid" : "skipped";
    } catch {
      // The settle RPC failed before committing (e.g. the delete hit a lock
      // timeout or deadlock), so our lease still holds. Schedule bounded
      // retries like the legacy path did — otherwise a persistently failing
      // delete would re-claim and re-call the provider forever without ever
      // reaching a terminal state.
      if (row.attempts < MAX_ATTEMPTS) {
        const nextAvailable = new Date(Date.parse(now) + retryDelayMs(row.attempts))
          .toISOString();
        const fenced = await fenceUpdate(admin, row, {
          status: "pending",
          available_at: nextAvailable,
          last_error_code: "subscription_delete_failed",
        });
        return fenced ? "retryable" : "skipped";
      }
      const fenced = await fenceUpdate(admin, row, {
        status: "dead_letter",
        last_error_code: "subscription_delete_failed",
      });
      return fenced ? "dead_letter" : "skipped";
    }
  }

  if (outcome === "retryable" && row.attempts < MAX_ATTEMPTS) {
    const nextAvailable = new Date(Date.parse(now) + retryDelayMs(row.attempts))
      .toISOString();
    const settled = await settleDelivery(
      admin,
      row,
      "pending",
      errorCode,
      undefined,
      nextAvailable,
    );
    return settled ? "retryable" : "skipped";
  }

  const settled = await settleDelivery(admin, row, "dead_letter", errorCode);
  return settled ? "dead_letter" : "skipped";
}

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const expectedToken = Deno.env.get("PUSH_DELIVERY_TOKEN");
  const authorization = request.headers.get("Authorization");
  if (
    !expectedToken || !authorization?.startsWith("Bearer ") ||
    !constantTimeEqual(authorization.slice(7), expectedToken)
  ) {
    return json({ error: "unauthorized" }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const vapidSubject = Deno.env.get("VAPID_SUBJECT");
  const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY");
  const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY");
  if (
    !supabaseUrl || !serviceRoleKey || !vapidSubject || !vapidPublicKey ||
    !vapidPrivateKey
  ) {
    return json({ error: "delivery_not_configured" }, 500);
  }

  let body: { limit?: unknown; now?: unknown } = {};
  try {
    body = await request.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  let limit: number;
  let now: string;
  try {
    limit = parseLimit(body.limit);
    now = parseNow(body.now);
  } catch (error) {
    return json({
      error: error instanceof Error ? error.message : "invalid_request",
    }, 400);
  }

  webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey);
  const admin = createClient(supabaseUrl, serviceRoleKey);
  const { data: rows, error } = await admin.rpc(
    "claim_notification_push_deliveries",
    {
      p_limit: limit,
      p_now: now,
      // Opt into the extended lease-context response (claimed_at +
      // owner_generation); the two-argument legacy overload stays untouched.
      p_return_lease_context: true,
    },
  );
  if (error) return json({ error: "delivery_claim_failed" }, 503);

  const deliveryRows = (rows ?? []) as DeliveryRow[];

  // Notification recipients are immutable per enqueue, so they can be
  // batch-loaded once. Subscription ownership is NOT cached here: it is
  // re-read per delivery immediately before sending (generation fencing).
  const notificationRecipients = new Map<string, string>();
  if (deliveryRows.length > 0) {
    const notificationsResult = await admin
      .from("notifications")
      .select("id, recipient_profile_id")
      .in(
        "id",
        [...new Set(deliveryRows.map((row) => row.notification_id))],
      );
    if (notificationsResult.error) {
      return json({ error: "subscription_validation_failed" }, 503);
    }
    for (const notification of notificationsResult.data ?? []) {
      notificationRecipients.set(
        notification.id as string,
        notification.recipient_profile_id as string,
      );
    }
  }

  const summary: DeliverySummary = {
    claimed: deliveryRows.length,
    sent: 0,
    retryable: 0,
    endpoint_invalid: 0,
    cancelled: 0,
    dead_letter: 0,
    skipped: 0,
  };
  for (const row of deliveryRows) {
    const recipient = notificationRecipients.get(row.notification_id);
    if (recipient === undefined) {
      // The notification vanished after fan-out; cancel under the lease
      // fence so the scheduler never re-claims it.
      try {
        const fenced = await fenceUpdate(admin, row, {
          status: "cancelled",
          last_error_code: "notification_missing",
        });
        summary[fenced ? "cancelled" : "skipped"] += 1;
      } catch {
        summary.skipped += 1;
      }
      continue;
    }
    try {
      const outcome = await processDelivery(admin, row, recipient, now);
      summary[outcome] += 1;
    } catch {
      summary.skipped += 1;
    }
  }
  return json(summary);
});
