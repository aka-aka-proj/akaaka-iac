import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { parseStaleDays, type CleanupSummary } from "../_shared/push-subscription-cleanup.ts";

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
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ error: "cleanup_not_configured" }, 500);
  }

  let body: { stale_days?: unknown } = {};
  try {
    body = await request.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  let staleDays: number;
  try {
    staleDays = parseStaleDays(body.stale_days);
  } catch {
    return json({ error: "invalid_stale_days" }, 400);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey);
  const { data, error } = await admin.rpc("cleanup_stale_push_subscriptions", {
    p_stale_days: staleDays,
  });
  if (error || typeof data !== "number") {
    return json({ error: "cleanup_failed" }, 503);
  }

  const summary: CleanupSummary = {
    deleted: data,
    stale_days: staleDays,
  };
  return json(summary);
});
