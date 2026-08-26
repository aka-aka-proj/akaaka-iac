#!/usr/bin/env -S deno run --allow-env --allow-net

/**
 * Authenticated Test Agent — CLI tool for managing Supabase test user accounts.
 *
 * Uses service_role key to create confirmed test users and return JWTs for
 * authenticated API calls. Designed for CI/staging use only.
 *
 * Usage:
 *   deno run --allow-env --allow-net --config supabase/functions/deno.json \
 *     supabase/functions/testing/authenticated-test-agent.ts <command> [options]
 *
 * Commands:
 *   create [email]     Create a confirmed test user with profile; auto-generates email
 *   list               List all test accounts (dry-run — no changes)
 *   cleanup            Delete all test accounts and their associated data
 */

import { createClient } from "@supabase/supabase-js";

// ── Constants ──────────────────────────────────────────────────────
const TEST_EMAIL_PREFIX = "iac.patrol.test.";
const DEFAULT_PASSWORD = "test-password-123!";

// ── Types ──────────────────────────────────────────────────────────
interface TestAccount {
  id: string;
  email: string;
  created_at: string;
}

interface TestUserResult {
  email: string;
  access_token: string;
  expires_at: number;
}

// ── Helpers ────────────────────────────────────────────────────────
function getEnvOrThrow(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(
      `Missing required env var: ${name}. ` +
      `Set it to proceed.\n` +
      `  export ${name}="your-value"`,
    );
  }
  return value;
}

function testEmail(email: string): boolean {
  return email.startsWith(TEST_EMAIL_PREFIX);
}

/** Generate a unique test email with timestamp + random suffix. */
function generateTestEmail(): string {
  const ts = Date.now().toString(36);
  const rand = Math.random().toString(36).slice(2, 8);
  return `${TEST_EMAIL_PREFIX}${ts}.${rand}@gmail.com`;
}

function getAdminClient() {
  const supabaseUrl = getEnvOrThrow("SUPABASE_URL");
  const serviceRoleKey = getEnvOrThrow("SERVICE_ROLE_KEY");
  return createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

/** Return ALL users from supabase auth (paginated fetch). */
async function listAllUsers(adminClient: ReturnType<typeof getAdminClient>) {
  const allUsers: Array<{ id: string; email: string | undefined; created_at: string }> = [];
  let page = 1;
  const perPage = 100;
  let hasMore = true;

  while (hasMore) {
    const { data, error } = await adminClient.auth.admin.listUsers({
      page,
      perPage,
    });
    if (error) {
      throw new Error(`Failed to list users (page ${page}): ${error.message}`);
    }
    if (!data?.users || data.users.length === 0) break;
    for (const u of data.users) {
      allUsers.push({ id: u.id, email: u.email, created_at: u.created_at });
    }
    hasMore = data.users.length >= perPage;
    page += 1;
  }

  return allUsers;
}

/**
 * Delete a test user and all associated data that references profiles
 * (mirrors the delete-account Edge Function logic).
 */
async function deleteTestUser(
  adminClient: ReturnType<typeof getAdminClient>,
  userId: string,
): Promise<string | null> {
  const serviceClient = adminClient;

  // Delete related data that references profiles (no ON DELETE CASCADE).
  // Reports targeting an event must be removed before the event itself because
  // reports.target_event_id also has the default NO ACTION delete behavior.
  const tablesToClean: [string, string][] = [
    ["reports", "target_event_id"],
    ["events", "creator_id"],
    ["event_threads", "profile_id"],
    ["event_registrations", "reviewed_by"],
    ["recommendations", "from_profile_id"],
    ["recommendations", "to_profile_id"],
    ["blocks", "blocker_id"],
    ["blocks", "blocked_id"],
    ["reports", "reporter_id"],
    ["reports", "target_profile_id"],
    ["moderation_actions", "admin_id"],
    ["moderation_actions", "target_profile_id"],
    ["audit_logs", "actor_id"],
    ["audit_logs", "target_profile_id"],
  ];

  const cleanupErrors: string[] = [];
  for (const [table, column] of tablesToClean) {
    const { error: delErr } = await serviceClient
      .from(table)
      .delete()
      .eq(column, userId);
    if (delErr) {
      cleanupErrors.push(`${table}.${column}: ${delErr.message}`);
    }
  }

  if (cleanupErrors.length > 0) {
    return `Failed to clean related data: ${cleanupErrors.join("; ")}`;
  }

  // Delete profile
  const { error: deleteProfileError } = await serviceClient
    .from("profiles")
    .delete()
    .eq("id", userId);
  if (deleteProfileError) {
    return `Failed to delete profile: ${deleteProfileError.message}`;
  }

  // Delete auth user
  const { error: deleteUserError } = await serviceClient.auth.admin.deleteUser(userId);
  if (deleteUserError) {
    return `Failed to delete auth user: ${deleteUserError.message}`;
  }

  return null; // success
}

// ── Commands ────────────────────────────────────────────────────────

/**
 * Create a confirmed test user with profile and return a usable JWT.
 */
async function cmdCreate(emailArg?: string): Promise<void> {
  const email = emailArg ?? generateTestEmail();

  // Restrict custom emails to test prefix so cleanup can find them
  if (!testEmail(email)) {
    console.error(
      `Error: Custom email must start with "${TEST_EMAIL_PREFIX}" prefix ` +
      `to be discoverable by cleanup. Generated email: ${generateTestEmail()}`,
    );
    Deno.exit(1);
  }

  const adminClient = getAdminClient();

  // 1. Create confirmed user via admin API
  const { data: user, error: createError } = await adminClient.auth.admin.createUser({
    email,
    password: DEFAULT_PASSWORD,
    email_confirm: true,
    user_metadata: { test_account: true, created_by: "authenticated-test-agent" },
  });

  if (createError) {
    console.error(`Failed to create test user ${email}: ${createError.message}`);
    Deno.exit(1);
  }
  if (!user?.user) {
    console.error("User creation returned empty response");
    Deno.exit(1);
  }

  const userId = user.user.id;

  // 2. Create a minimal profile so authenticated API calls (e.g. create-issue,
  //    request-venue-application) referencing profiles FK succeed.
  const defaultProfile = {
    id: userId,
    display_name: email.split("@")[0],
    role_status: "general",
    reputation_score: 0,
  };

  const { error: profileError } = await adminClient
    .from("profiles")
    .upsert(defaultProfile, { onConflict: "id" });

  if (profileError) {
    console.error(`Failed to create profile for ${email}: ${profileError.message}`);
    await deleteTestUser(adminClient, userId);
    Deno.exit(1);
  }

  // 3. Sign in to get session (confirms the user works end-to-end)
  const userClient = createClient(getEnvOrThrow("SUPABASE_URL"), getEnvOrThrow("SUPABASE_ANON_KEY"));
  const { data: session, error: signInError } = await userClient.auth.signInWithPassword({
    email,
    password: DEFAULT_PASSWORD,
  });

  if (signInError || !session?.session) {
    console.error(`User created (${userId}) but sign-in failed: ${signInError?.message ?? "no session"}`);
    await deleteTestUser(adminClient, userId);
    Deno.exit(1);
  }

  const result: TestUserResult = {
    email,
    access_token: session.session.access_token,
    expires_at: Math.floor(Date.now() / 1000) + session.session.expires_in,
  };

  console.log(JSON.stringify(result));
}

/**
 * List all test accounts (matching test email prefix).
 * Paginated — fetches all users.
 */
async function cmdList(): Promise<void> {
  const adminClient = getAdminClient();
  let users;
  try {
    users = await listAllUsers(adminClient);
  } catch (err) {
    console.error(`Failed to list users: ${(err as Error).message}`);
    Deno.exit(1);
  }

  const testAccounts: TestAccount[] = users
    .filter((u) => u.email && testEmail(u.email))
    .map((u) => ({
      id: u.id,
      email: u.email!,
      created_at: u.created_at,
    }));

  console.log(JSON.stringify({ count: testAccounts.length, accounts: testAccounts }, null, 2));
}

/**
 * Delete all test accounts and their associated data.
 * Paginated — fetches all users. Exits non-zero if any deletion fails.
 */
async function cmdCleanup(): Promise<void> {
  const adminClient = getAdminClient();
  let users;
  try {
    users = await listAllUsers(adminClient);
  } catch (err) {
    console.error(`Failed to list users: ${(err as Error).message}`);
    Deno.exit(1);
  }

  const testAccounts = users.filter((u) => u.email && testEmail(u.email));

  let deleted = 0;
  let failed = 0;
  const errors: string[] = [];

  for (const user of testAccounts) {
    const deleteErr = await deleteTestUser(adminClient, user.id);
    if (deleteErr) {
      errors.push(`Failed to delete ${user.email} (${user.id}): ${deleteErr}`);
      failed += 1;
    } else {
      deleted += 1;
    }
  }

  console.log(JSON.stringify({ deleted, failed, total_found: testAccounts.length, errors }, null, 2));

  if (failed > 0) {
    Deno.exit(1);
  }
}

// ── Main ────────────────────────────────────────────────────────────
async function main() {
  const command = Deno.args[0];

  if (!command || command === "--help" || command === "-h") {
    console.log(`
Authenticated Test Agent — create/list/cleanup Supabase test accounts

Usage:
  deno run --allow-env --allow-net --config supabase/functions/deno.json \\
    supabase/functions/testing/authenticated-test-agent.ts <command> [options]

Commands:
  create [email]    Create a confirmed test user (auto-generates email if omitted)
                    Output: JSON { email, access_token, expires_at }
  list              List all test accounts matching prefix "${TEST_EMAIL_PREFIX}"
  cleanup           Delete all test accounts matching prefix "${TEST_EMAIL_PREFIX}"
  --help, -h        Show this help

Required env vars:
  SUPABASE_URL         Supabase project URL
  SERVICE_ROLE_KEY     service_role key (admin privileges)
  SUPABASE_ANON_KEY    anon key (for sign-in verification)

Note: Custom \`create\` email must start with "${TEST_EMAIL_PREFIX}".
      Cleanup performs full cascade deletion (events, threads, etc.).
`);
    Deno.exit(0);
  }

  switch (command) {
    case "create":
      await cmdCreate(Deno.args[1]);
      break;
    case "list":
      await cmdList();
      break;
    case "cleanup":
      await cmdCleanup();
      break;
    default:
      console.error(`Unknown command: ${command}. Use --help for usage.`);
      Deno.exit(1);
  }
}

await main();
