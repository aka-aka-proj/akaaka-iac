import { createClient } from "@supabase/supabase-js";
import {
  classifyProviderStatus,
  createProviderKey,
  deleteProviderKey,
  decryptProviderKey,
  encryptProviderKey,
  metadataFromProvider,
} from "../_shared/llm-key.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (
    req.method !== "GET" && req.method !== "POST" && req.method !== "DELETE"
  ) return json({ error: "method_not_allowed" }, 405);

  const authorization = req.headers.get("Authorization");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (
    !authorization?.startsWith("Bearer ") || !supabaseUrl || !anonKey ||
    !serviceRoleKey
  ) {
    return json({ error: "unauthorized" }, 401);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
  });
  const { data: { user }, error: userError } = await userClient.auth.getUser();
  if (userError || !user) return json({ error: "unauthorized" }, 401);

  const admin = createClient(supabaseUrl, serviceRoleKey);
  const { data: existing } = await admin
    .from("user_llm_api_keys")
    .select(
      "provider, provider_key_hash, encrypted_key, limit_usd, limit_reset, disabled, usage_usd, limit_remaining_usd, provider_created_at, provider_updated_at",
    )
    .eq("user_id", user.id)
    .maybeSingle();
  if (req.method === "DELETE") {
    if (!existing) {
      return new Response(null, { status: 204, headers: corsHeaders });
    }
    const managementKey = Deno.env.get("OPENROUTER_MANAGEMENT_API_KEY");
    if (!managementKey) {
      return json({ error: "llm_key_service_not_configured" }, 500);
    }

    try {
      await deleteProviderKey(managementKey, existing.provider_key_hash);
      const { error } = await admin.from("user_llm_api_keys").delete().eq(
        "user_id",
        user.id,
      );
      if (error) {
        console.error("[llm-key] local deletion failed", error.message);
        return json({ error: "internal_error" }, 500);
      }
      return new Response(null, { status: 204, headers: corsHeaders });
    } catch (error) {
      console.error(
        "[llm-key] provider deletion failed",
        error instanceof Error ? error.message : "unknown",
      );
      return json({ error: "dependency_unavailable" }, 503);
    }
  }

  if (existing) {
    const { encrypted_key: _encryptedKey, ...existingMetadata } = existing;
    if (req.method === "GET") return json(existingMetadata);
    const encryptionSecret = Deno.env.get("OPENROUTER_KEY_ENCRYPTION_SECRET");
    if (!encryptionSecret) return json({ error: "llm_key_service_not_configured" }, 500);
    try {
      const providerKey = await decryptProviderKey(existing.encrypted_key, encryptionSecret);
      return json({ ...existingMetadata, provider_key: providerKey });
    } catch {
      return json({ error: "llm_key_unavailable" }, 503);
    }
  }
  if (req.method === "GET") {
    return json({ error: "llm_key_not_provisioned" }, 409);
  }

  const managementKey = Deno.env.get("OPENROUTER_MANAGEMENT_API_KEY");
  const encryptionSecret = Deno.env.get("OPENROUTER_KEY_ENCRYPTION_SECRET");
  const workspaceId = Deno.env.get("OPENROUTER_WORKSPACE_ID");
  const limit = Number(Deno.env.get("OPENROUTER_USER_KEY_LIMIT_USD"));
  const limitReset = Deno.env.get("OPENROUTER_USER_KEY_LIMIT_RESET");
  if (
    !managementKey || !encryptionSecret || !workspaceId ||
    !Number.isFinite(limit) ||
    limit < 0 || !limitReset ||
    !["daily", "weekly", "monthly"].includes(limitReset)
  ) {
    return json({ error: "llm_key_service_not_configured" }, 500);
  }

  const keyName = `akaaka-user-${user.id.replaceAll("-", "")}`;
  let created: Awaited<ReturnType<typeof createProviderKey>>;
  try {
    created = await createProviderKey(
      managementKey,
      keyName,
      limit,
      limitReset,
      workspaceId,
    );
  } catch (error) {
    const providerStatus = error instanceof Error
      ? Number(error.message.match(/^provider_create_failed:(\d+)$/)?.[1])
      : NaN;
    const providerError = Number.isInteger(providerStatus)
      ? classifyProviderStatus(providerStatus)
      : "provider_unavailable";
    console.error(
      "[llm-key] provider provisioning failed",
      error instanceof Error ? error.message : "unknown",
    );
    return json({ error: "dependency_unavailable", provider_error: providerError }, 503);
  }

  try {
    const encryptedKey = await encryptProviderKey(
      created.plaintext,
      encryptionSecret,
    );
    const metadata = metadataFromProvider(created.provider);
    const { data, error } = await admin.from("user_llm_api_keys").insert({
      user_id: user.id,
      encrypted_key: encryptedKey,
      key_version: 1,
      ...metadata,
    }).select(
      "provider, provider_key_hash, limit_usd, limit_reset, disabled, usage_usd, limit_remaining_usd, provider_created_at, provider_updated_at",
    ).single();
    if (!error && data) return json({ ...data, provider_key: created.plaintext }, 201);

    const { data: raced } = await admin.from("user_llm_api_keys")
      .select(
        "provider, provider_key_hash, limit_usd, limit_reset, disabled, usage_usd, limit_remaining_usd, provider_created_at, provider_updated_at",
      )
      .eq("user_id", user.id).maybeSingle();
    if (raced) {
      await deleteProviderKey(managementKey, created.provider.hash);
      return json(raced);
    }
    await deleteProviderKey(managementKey, created.provider.hash);
    console.error(
      "[llm-key] local persistence failed",
      error?.message ?? "unknown",
    );
    return json({ error: "internal_error" }, 500);
  } catch (error) {
    await deleteProviderKey(managementKey, created.provider.hash);
    console.error(
      "[llm-key] encryption or persistence failed",
      error instanceof Error ? error.message : "unknown",
    );
    return json({ error: "internal_error" }, 500);
  }
});
