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
  notification_type:
    | "new_event"
    | "new_issue"
    | "new_follow"
    | "venue_application"
    | "event_invitation"
    | "event_announcement";
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

async function updateDelivery(
  admin: AdminClient,
  deliveryId: string,
  patch: Record<string, unknown>,
): Promise<void> {
  const { error } = await admin
    .from("notification_push_deliveries")
    .update({ ...patch, updated_at: new Date().toISOString() })
    .eq("id", deliveryId)
    .eq("status", "processing");
  if (error) throw new Error("delivery_state_update_failed");
}

async function processDelivery(
  admin: AdminClient,
  row: DeliveryRow,
  now: string,
): Promise<keyof Omit<DeliverySummary, "claimed" | "skipped">> {
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
    await updateDelivery(admin, row.delivery_id, {
      status: "dead_letter",
      last_error_code: "invalid_notification_target",
    });
    return "dead_letter";
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
    await updateDelivery(admin, row.delivery_id, {
      status: "sent",
      sent_at: now,
      last_error_code: null,
    });
    return "sent";
  }

  const errorCode = stableErrorCode(status);
  if (outcome === "endpoint_invalid") {
    await admin.from("push_subscriptions").delete().eq(
      "id",
      row.push_subscription_id,
    );
    await updateDelivery(admin, row.delivery_id, {
      status: "endpoint_invalid",
      last_error_code: errorCode,
    });
    return "endpoint_invalid";
  }

  if (outcome === "retryable" && row.attempts < MAX_ATTEMPTS) {
    const nextAvailable = new Date(Date.parse(now) + retryDelayMs(row.attempts))
      .toISOString();
    await updateDelivery(admin, row.delivery_id, {
      status: "pending",
      available_at: nextAvailable,
      last_error_code: errorCode,
    });
    return "retryable";
  }

  await updateDelivery(admin, row.delivery_id, {
    status: "dead_letter",
    last_error_code: errorCode,
  });
  return "dead_letter";
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
    },
  );
  if (error) return json({ error: "delivery_claim_failed" }, 503);

  const summary: DeliverySummary = {
    claimed: rows?.length ?? 0,
    sent: 0,
    retryable: 0,
    endpoint_invalid: 0,
    dead_letter: 0,
    skipped: 0,
  };
  for (const row of (rows ?? []) as DeliveryRow[]) {
    try {
      const outcome = await processDelivery(admin, row, now);
      summary[outcome] += 1;
    } catch {
      summary.skipped += 1;
    }
  }
  return json(summary);
});
