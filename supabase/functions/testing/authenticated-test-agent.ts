#!/usr/bin/env -S deno run --allow-env --allow-net

import { createClient } from "@supabase/supabase-js";

const TEST_EMAIL_PREFIX = "iac.patrol.test.";
const DEFAULT_PASSWORD = "test-password-123!";

interface TestUserResult { email: string; access_token: string; expires_at: number; }

function getEnvOrThrow(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`Missing: ${name}`);
  return v;
}
function testEmail(e: string): boolean { return e.startsWith(TEST_EMAIL_PREFIX); }
function genEmail(): string {
  return `${TEST_EMAIL_PREFIX}${Date.now().toString(36)}.${Math.random().toString(36).slice(2, 8)}@gmail.com`;
}
function adminClient() {
  return createClient(getEnvOrThrow("SUPABASE_URL"), getEnvOrThrow("SERVICE_ROLE_KEY"), {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

async function allUsers(c: ReturnType<typeof adminClient>) {
  const r: Array<{ id: string; email: string | undefined; created_at: string }> = [];
  let p = 1;
  for (;;) {
    const { data, error } = await c.auth.admin.listUsers({ page: p, perPage: 100 });
    if (error) throw new Error(`listUsers p${p}: ${error.message}`);
    if (!data?.users?.length) break;
    for (const u of data.users) r.push({ id: u.id, email: u.email, created_at: u.created_at });
    if (data.users.length < 100) break;
    p++;
  }
  return r;
}

async function delUser(c: ReturnType<typeof adminClient>, uid: string): Promise<string | null> {
  for (const [tbl, col] of [
    ["events", "creator_id"], ["event_threads", "profile_id"], ["event_registrations", "reviewed_by"],
    ["recommendations", "from_profile_id"], ["recommendations", "to_profile_id"],
    ["blocks", "blocker_id"], ["blocks", "blocked_id"],
    ["reports", "reporter_id"], ["reports", "target_profile_id"],
    ["moderation_actions", "admin_id"], ["moderation_actions", "target_profile_id"],
    ["audit_logs", "actor_id"], ["audit_logs", "target_profile_id"],
  ] as const) {
    const { error } = await c.from(tbl).delete().eq(col, uid);
    if (error) console.error(`clean ${tbl}.${col}: ${error.message}`);
  }
  const { error: pe } = await c.from("profiles").delete().eq("id", uid);
  if (pe) return `profile delete: ${pe.message}`;
  const { error: ae } = await c.auth.admin.deleteUser(uid);
  if (ae) return `auth delete: ${ae.message}`;
  return null;
}

async function cmdCreate(emailArg?: string) {
  const email = emailArg ?? genEmail();
  if (!testEmail(email)) { console.error("Email must match test prefix"); Deno.exit(1); }
  const c = adminClient();
  const { data: u, error: ce } = await c.auth.admin.createUser({ email, password: DEFAULT_PASSWORD, email_confirm: true });
  if (ce || !u?.user) { console.error(`Create fail: ${ce?.message}`); Deno.exit(1); }
  const { error: pe } = await c.from("profiles").upsert({
    id: u.user.id, display_name: email.split("@")[0], role_status: "general", reputation_score: 0,
  }, { onConflict: "id" });
  if (pe) { console.error(`Profile fail: ${pe.message}`); await delUser(c, u.user.id); Deno.exit(1); }
  const uc = createClient(getEnvOrThrow("SUPABASE_URL"), getEnvOrThrow("SUPABASE_ANON_KEY"));
  const { data: s, error: se } = await uc.auth.signInWithPassword({ email, password: DEFAULT_PASSWORD });
  if (se || !s?.session) { console.error(`Signin fail: ${se?.message}`); await delUser(c, u.user.id); Deno.exit(1); }
  console.log(JSON.stringify({ email, access_token: s.session.access_token, expires_at: Math.floor(Date.now() / 1000) + s.session.expires_in }));
}

async function cmdList() {
  const users = await allUsers(adminClient());
  const accts = users.filter((u) => u.email && testEmail(u.email)).map((u) => ({ id: u.id, email: u.email, created_at: u.created_at }));
  console.log(JSON.stringify({ count: accts.length, accounts: accts }, null, 2));
}

async function cmdCleanup() {
  const c = adminClient();
  const users = await allUsers(c);
  const todo = users.filter((u) => u.email && testEmail(u.email));
  let deleted = 0, failed = 0;
  for (const u of todo) {
    const err = await delUser(c, u.id);
    if (err) { console.error(`Fail ${u.email}: ${err}`); failed++; } else deleted++;
  }
  console.log(JSON.stringify({ deleted, failed, total: todo.length }));
  if (failed > 0) Deno.exit(1);
}

const m = Deno.args[0];
if (!m || m === "--help") { console.log("Commands: create [email], list, cleanup"); Deno.exit(0); }
const cmds: Record<string, () => Promise<void>> = { create: () => cmdCreate(Deno.args[1]), list: cmdList, cleanup: cmdCleanup };
if (!cmds[m]) { console.error(`Unknown: ${m}`); Deno.exit(1); }
await cmds[m]();