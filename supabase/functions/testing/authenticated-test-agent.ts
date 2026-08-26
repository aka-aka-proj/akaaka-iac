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
 *   create [email]     Create a confirmed test user; auto-generates email if omitted
 *   cleanup            Delete all test accounts (email matching test prefix)
 *   list               List all test accounts (dry-run — no changes)
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

// ── Commands ────────────────────────────────────────────────────────

/**
 * Create a confirmed test user and return a usable JWT.
 *
 * POST /auth/v1/admin/users  (requires service_role key)
 * The admin API creates the user and immediately confirms their email,
 * bypassing the email confirmation flow.
 *
 * After creation, we sign in with password to get a fresh JWT session.
 */
async function cmdCreate(emailArg?: string): Promise<void> {
  const email = emailArg ?? generateTestEmail();
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

  // 2. Sign in to get session (confirms the user works end-to-end)
  const userClient = createClient(getEnvOrThrow("SUPABASE_URL"), getEnvOrThrow("SUPABASE_ANON_KEY"));
  const { data: session, error: signInError } = await userClient.auth.signInWithPassword({
    email,
    password: DEFAULT_PASSWORD,
  });

  if (signInError || !session?.session) {
    // User was created but sign-in failed — something is wrong
    console.error(`User created (${user.user.id}) but sign-in failed: ${signInError?.message ?? "no session"}`);
    // Clean up the user we just created
    await adminClient.auth.admin.deleteUser(user.user.id);
    Deno.exit(1);
  }

  const result: TestUserResult = {
    email,
    access_token: session.session.access_token,
    expires_at: Math.floor(Date.now() / 1000) + session.session.expires_in,
  };

  // Machine-readable JSON output for CI consumption
  console.log(JSON.stringify(result));
}

/**
 * List all test accounts (matching test email prefix).
 * Dry-run — never deletes anything.
 */
async function cmdList(): Promise<void> {
  const adminClient = getAdminClient();
  const { data: users, error } = await adminClient.auth.admin.listUsers();

  if (error) {
    console.error(`Failed to list users: ${error.message}`);
    Deno.exit(1);
  }

  const testAccounts: TestAccount[] = (users?.users ?? [])
    .filter((u) => u.email && testEmail(u.email))
    .map((u) => ({
      id: u.id,
      email: u.email!,
      created_at: u.created_at,
    }));

  console.log(JSON.stringify({ count: testAccounts.length, accounts: testAccounts }, null, 2));
}

/**
 * Delete all test accounts (matching test email prefix).
 * Reports count of deleted accounts.
 */
async function cmdCleanup(): Promise<void> {
  const adminClient = getAdminClient();
  const { data: users, error } = await adminClient.auth.admin.listUsers();

  if (error) {
    console.error(`Failed to list users: ${error.message}`);
    Deno.exit(1);
  }

  const testAccounts = (users?.users ?? [])
    .filter((u) => u.email && testEmail(u.email));

  let deleted = 0;
  let failed = 0;

  for (const user of testAccounts) {
    const { error: deleteError } = await adminClient.auth.admin.deleteUser(user.id);
    if (deleteError) {
      console.error(`Failed to delete ${user.email} (${user.id}): ${deleteError.message}`);
      failed += 1;
    } else {
      deleted += 1;
    }
  }

  console.log(JSON.stringify({ deleted, failed, total_found: testAccounts.length }));
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