BEGIN;

SELECT plan(53);

-- Structural contracts -------------------------------------------------------

-- Contract-step landed (api/004 §Rollout ordering step 3): the global unique
-- constraint now exists alongside the legacy composite constraint; detailed
-- behavior lives in push_subscription_endpoint_unique_contract_step_test.sql.
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.push_subscriptions'::regclass
      AND conname = 'push_subscriptions_endpoint_unique'
      AND contype = 'u'
  ),
  'global endpoint unique is enforced as of the contract step'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.push_subscriptions'::regclass
      AND conname = 'push_subscriptions_profile_id_endpoint_key'
      AND contype = 'u'
  ),
  'legacy composite unique stays for client conflict-target compatibility'
);

SELECT ok(
  (SELECT pg_get_constraintdef(c.oid) LIKE '%cancelled%'
   FROM pg_constraint c
   WHERE c.conrelid = 'public.notification_push_deliveries'::regclass
     AND c.conname = 'notification_push_deliveries_status_check'),
  'delivery lifecycle includes the cancelled terminal state'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'idx_notification_push_deliveries_subscription_sent'
  ),
  'cleanup liveness predicate has its supporting index'
);

SELECT ok(
  (SELECT p.prosecdef
   FROM pg_proc p
   WHERE p.oid = 'public.subscribe_push_subscription(text,text,text,text,text)'::regprocedure),
  'subscribe RPC is security definer'
);

SELECT ok(
  (SELECT p.proconfig @> ARRAY['search_path=public, extensions']
   FROM pg_proc p
   WHERE p.oid = 'public.subscribe_push_subscription(text,text,text,text,text)'::regprocedure),
  'subscribe RPC fixes its search path'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.subscribe_push_subscription(text,text,text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.subscribe_push_subscription(text,text,text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.subscribe_push_subscription(text,text,text,text,text)', 'EXECUTE'),
  'only authenticated clients may execute the subscribe RPC'
);

SELECT ok(
  (SELECT p.prosecdef
   FROM pg_proc p
   WHERE p.oid = 'public.cleanup_stale_push_subscriptions(integer)'::regprocedure),
  'cleanup RPC is security definer'
);

SELECT ok(
  (SELECT p.proconfig @> ARRAY['search_path=public, extensions']
   FROM pg_proc p
   WHERE p.oid = 'public.cleanup_stale_push_subscriptions(integer)'::regprocedure),
  'cleanup RPC fixes its search path'
);

SELECT ok(
  has_function_privilege('service_role', 'public.cleanup_stale_push_subscriptions(integer)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.cleanup_stale_push_subscriptions(integer)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.cleanup_stale_push_subscriptions(integer)', 'EXECUTE'),
  'only the service role may execute the cleanup RPC'
);

SELECT ok(
  NOT has_table_privilege('authenticated', 'public.push_subscriptions', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.push_subscriptions', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.push_subscriptions', 'DELETE'),
  'contract-step closes direct INSERT, UPDATE, and DELETE'
);

SELECT ok(
  NOT has_table_privilege('authenticated', 'public.push_subscriptions', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.push_subscriptions', 'DELETE'),
  'browser clients must use controlled RPCs for subscription mutation'
);

SELECT ok(
  has_table_privilege('service_role', 'public.push_subscriptions', 'INSERT')
    AND has_table_privilege('service_role', 'public.push_subscriptions', 'SELECT'),
  'the service-side worker keeps full subscription access'
);

-- Behavioral contracts -------------------------------------------------------

INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT id, 'authenticated', 'authenticated', id::text || '@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()
FROM (
  VALUES
    ('00000000-0000-4000-8000-000000000301'::uuid),
    ('00000000-0000-4000-8000-000000000302'::uuid),
    ('00000000-0000-4000-8000-000000000303'::uuid),
    ('00000000-0000-4000-8000-000000000304'::uuid),
    ('00000000-0000-4000-8000-000000000305'::uuid)
) AS users(id);

INSERT INTO public.profiles (id, display_name, external_social_links)
SELECT id, 'Hygiene ' || right(id::text, 3), '[{"url":"https://local.test"}]'::jsonb
FROM auth.users;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000301', true);

SELECT lives_ok(
  $$SELECT public.subscribe_push_subscription(
    'https://push.local/e1', 'p256dh-a', 'auth-a', 'UA-A'
  )$$,
  'first profile can subscribe a fresh endpoint through the RPC'
);

SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions WHERE endpoint = 'https://push.local/e1'),
  1,
  'subscribing a fresh endpoint creates exactly one row'
);

SELECT id AS original_id
FROM public.push_subscriptions
WHERE endpoint = 'https://push.local/e1'
\gset hyg_

RESET ROLE;
INSERT INTO public.notifications (recipient_profile_id, notification_type, title, actor_profile_id)
VALUES ('00000000-0000-4000-8000-000000000301', 'new_follow', 'Hygiene follow', '00000000-0000-4000-8000-000000000302');

SELECT is(
  (SELECT count(*)::integer FROM public.notification_push_deliveries
   WHERE push_subscription_id = :'hyg_original_id'::uuid
     AND status = 'pending'),
  1,
  'notification fan-out queues undelivered work against the current owner'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000302', true);
SELECT public.subscribe_push_subscription(
  'https://push.local/e1', 'p256dh-a', 'auth-a', 'UA-B'
) AS transferred_id
\gset hyg_

SELECT is(
  :'hyg_transferred_id'::uuid,
  :'hyg_original_id'::uuid,
  'possession-proven takeover moves the same subscription row instead of duplicating it'
);

SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions WHERE endpoint = 'https://push.local/e1'),
  1,
  'one endpoint maps to exactly one row after the takeover'
);

SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions
   WHERE endpoint = 'https://push.local/e1'
     AND profile_id = '00000000-0000-4000-8000-000000000302'),
  1,
  'the endpoint is now owned by the second profile'
);

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000301', true);
SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions WHERE endpoint = 'https://push.local/e1'),
  0,
  'the previous owner loses visibility of the transferred endpoint'
);

RESET ROLE;
SELECT is(
  (SELECT status FROM public.notification_push_deliveries
   WHERE push_subscription_id = :'hyg_original_id'::uuid),
  'cancelled',
  'queued work for the previous owner is isolated by the move transaction'
);

SELECT is(
  (SELECT last_error_code FROM public.notification_push_deliveries
   WHERE push_subscription_id = :'hyg_original_id'::uuid),
  'endpoint_moved',
  'move-time isolation records a stable audit code'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000303', true);
SELECT throws_ok(
  $$SELECT public.subscribe_push_subscription(
    'https://push.local/e1', 'p256dh-x', 'auth-x', NULL
  )$$,
  'P0001',
  'endpoint_conflict',
  'knowing only the endpoint URL cannot hijack another profile subscription'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions
   WHERE endpoint = 'https://push.local/e1'
     AND profile_id = '00000000-0000-4000-8000-000000000302'),
  1,
  'a rejected hijack leaves the existing binding untouched'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000302', true);
SELECT lives_ok(
  $$SELECT public.subscribe_push_subscription(
    'https://push.local/e1', 'p256dh-b2', 'auth-b2', 'UA-B2'
  )$$,
  'the owning profile may rotate key material in place without the possession proof'
);

SELECT is(
  (SELECT p256dh FROM public.push_subscriptions WHERE id = :'hyg_original_id'::uuid),
  'p256dh-b2',
  'in-place rotation stores the refreshed key material'
);

-- Contract-step contract (api/004 §Rollout ordering step 3): direct client
-- INSERT is revoked once subscribe_push_subscription owns subscription
-- creation. UPDATE stays open until the p_mode refresh RPC lands
-- (frontend#92); DELETE stays open until unsubscribe_push_subscription and
-- its deletion log exist — revoking them early would strand user flows.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000301', true);
SELECT throws_ok(
  $$INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth)
    VALUES (
      '00000000-0000-4000-8000-000000000301',
      'https://push.local/e-direct',
      'p256dh-x',
      'auth-x'
    )$$,
  '42501',
  NULL,
  'contract-step revokes direct client INSERT; subscribe via RPC only'
);

SELECT throws_ok(
  format(
    'UPDATE public.push_subscriptions SET user_agent = %L WHERE id = %L',
    'ua-legacy',
    :'hyg_original_id'
  ),
  '42501',
  NULL,
  'contract-step revokes direct client UPDATE; refresh via RPC only'
);

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000303', true);
SELECT lives_ok(
  $$SELECT public.subscribe_push_subscription(
    'https://push.local/e9', 'p256dh-c', 'auth-c', 'UA-C'
  )$$,
  'third profile subscribes a disposable endpoint'
);

SELECT throws_ok(
  $$DELETE FROM public.push_subscriptions WHERE endpoint = 'https://push.local/e9'$$,
  '42501',
  NULL,
  'contract-step revokes direct client DELETE; unsubscribe via RPC only'
);

SELECT lives_ok(
  $$SELECT public.unsubscribe_push_subscription(
    'https://push.local/e9', 'p256dh-c', 'auth-c'
  )$$,
  'self-service unsubscribe uses the controlled RPC'
);

SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions WHERE endpoint = 'https://push.local/e9'),
  0,
  'self-service unsubscribe removes only the caller own row'
);

-- Move deferral contract ------------------------------------------------------

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000301', true);
SELECT lives_ok(
  $$SELECT public.subscribe_push_subscription(
    'https://push.local/e2-defer', 'p256dh-a2', 'auth-a2', NULL
  )$$,
  'owner subscribes the deferral-probe endpoint'
);

RESET ROLE;
INSERT INTO public.notifications (recipient_profile_id, notification_type, title, actor_profile_id)
VALUES ('00000000-0000-4000-8000-000000000301', 'new_follow', 'Hygiene defer follow', '00000000-0000-4000-8000-000000000305');

UPDATE public.notification_push_deliveries d
SET status = 'processing',
    claimed_at = timezone('utc', now())
FROM public.push_subscriptions ps
WHERE ps.endpoint = 'https://push.local/e2-defer'
  AND d.push_subscription_id = ps.id;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000302', true);
SELECT throws_ok(
  $$SELECT public.subscribe_push_subscription(
    'https://push.local/e2-defer', 'p256dh-a2', 'auth-a2', 'UA-B'
  )$$,
  'P0001',
  'endpoint_move_deferred',
  'transfer defers while an active send lease holds the endpoint'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions
   WHERE endpoint = 'https://push.local/e2-defer'
     AND profile_id = '00000000-0000-4000-8000-000000000301'),
  1,
  'deferred transfer leaves ownership unchanged'
);

RESET ROLE;
UPDATE public.notification_push_deliveries d
SET claimed_at = timezone('utc', now()) - interval '6 minutes'
FROM public.push_subscriptions ps
WHERE ps.endpoint = 'https://push.local/e2-defer'
  AND d.push_subscription_id = ps.id;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000302', true);
SELECT lives_ok(
  $$SELECT public.subscribe_push_subscription(
    'https://push.local/e2-defer', 'p256dh-a2', 'auth-a2', 'UA-B'
  )$$,
  'transfer succeeds once the send lease expires'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.notification_push_deliveries d
   JOIN public.push_subscriptions ps ON ps.id = d.push_subscription_id
   WHERE ps.endpoint = 'https://push.local/e2-defer'
     AND d.status = 'cancelled'),
  1,
  'deferred-then-completed move still quarantines previous-owner queue'
);

-- Expand-window duplicate convergence ----------------------------------------

RESET ROLE;
-- Contract-step: cross-profile duplicate pairs can no longer exist; the
-- takeover path is exercised against a single foreign binding instead.
INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth, updated_at)
VALUES ('00000000-0000-4000-8000-000000000301', 'https://push.local/e-dup', 'p256dh-dup', 'auth-dup', now() - interval '1 hour');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000302', true);
SELECT lives_ok(
  $$SELECT public.subscribe_push_subscription(
    'https://push.local/e-dup', 'p256dh-dup', 'auth-dup', 'UA-B'
  )$$,
  'possession-matched takeover converges a legacy duplicate pair'
);

SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions WHERE endpoint = 'https://push.local/e-dup'),
  1,
  'duplicate endpoint rows collapse into exactly one binding'
);

SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions
   WHERE endpoint = 'https://push.local/e-dup'
     AND profile_id = '00000000-0000-4000-8000-000000000302'),
  1,
  'the surviving binding belongs to the possessing profile'
);

-- Hijack-with-self-row attack (codex round-3): an attacker planting their own
-- freshest row must never purge a foreign binding whose keys they lack.

RESET ROLE;
INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth, updated_at)
VALUES ('00000000-0000-4000-8000-000000000301', 'https://push.local/e-hijack', 'p256dh-victim', 'auth-victim', now() - interval '1 hour');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000303', true);
SELECT throws_ok(
  $$SELECT public.subscribe_push_subscription(
    'https://push.local/e-hijack', 'p256dh-c', 'auth-c', 'UA-C'
  )$$,
  'P0001',
  'endpoint_conflict',
  'planted self-row cannot bind while foreign keys hold the endpoint'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions
   WHERE endpoint = 'https://push.local/e-hijack'
     AND profile_id = '00000000-0000-4000-8000-000000000303'),
  0,
  'rejected hijack plants no binding of its own'
);

SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions
   WHERE endpoint = 'https://push.local/e-hijack'
     AND profile_id = '00000000-0000-4000-8000-000000000301'),
  1,
  'victim binding survives an attacker refresh that lacks victim key material'
);

-- Claim path contracts --------------------------------------------------------

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000301', true);
SELECT public.subscribe_push_subscription(
  'https://push.local/e-live', 'p256dh-live', 'auth-live', NULL
);

RESET ROLE;
INSERT INTO public.notifications (recipient_profile_id, notification_type, title, actor_profile_id)
VALUES ('00000000-0000-4000-8000-000000000301', 'new_follow', 'Hygiene live follow', '00000000-0000-4000-8000-000000000303');

SET LOCAL ROLE service_role;
CREATE TEMP TABLE claim_result ON COMMIT DROP AS
SELECT * FROM public.claim_notification_push_deliveries(25, timezone('utc', now()));

SELECT ok(
  EXISTS (SELECT 1 FROM claim_result),
  'claim returns deliverable jobs with a live subscription'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM claim_result cr
    JOIN public.push_subscriptions ps ON ps.id = cr.push_subscription_id
    WHERE ps.profile_id = '00000000-0000-4000-8000-000000000301'
  ),
  'claimed jobs reference a live subscription owned by the recipient profile'
);

RESET ROLE;
INSERT INTO public.notification_push_deliveries (notification_id, push_subscription_id, idempotency_key)
SELECT n.id, gen_random_uuid(), 'hygiene-orphan-fixture'
FROM public.notifications n
WHERE n.recipient_profile_id = '00000000-0000-4000-8000-000000000301'
  AND n.notification_type = 'new_follow'
  AND n.actor_profile_id = '00000000-0000-4000-8000-000000000303';

SET LOCAL ROLE service_role;
SELECT count(*) FROM public.claim_notification_push_deliveries(25, timezone('utc', now()));

SELECT is(
  (SELECT status FROM public.notification_push_deliveries WHERE idempotency_key = 'hygiene-orphan-fixture'),
  'cancelled',
  'work whose target subscription vanished is fenced to cancelled instead of retried'
);

SELECT is(
  (SELECT last_error_code FROM public.notification_push_deliveries WHERE idempotency_key = 'hygiene-orphan-fixture'),
  'subscription_missing',
  'cancellation records a stable audit code for observability'
);

-- Cleanup liveness contracts --------------------------------------------------

RESET ROLE;
INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth, updated_at)
VALUES ('00000000-0000-4000-8000-000000000301', 'https://push.local/stale-but-delivered', 'p', 'a', now() - interval '200 days');

INSERT INTO public.notifications (recipient_profile_id, notification_type, title, actor_profile_id)
VALUES ('00000000-0000-4000-8000-000000000301', 'new_follow', 'Hygiene delivered follow', '00000000-0000-4000-8000-000000000304');

UPDATE public.notification_push_deliveries d
SET status = 'sent',
    sent_at = timezone('utc', now())
FROM public.push_subscriptions ps
WHERE ps.endpoint = 'https://push.local/stale-but-delivered'
  AND d.push_subscription_id = ps.id
  AND d.status = 'pending';

INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth, updated_at)
VALUES ('00000000-0000-4000-8000-000000000301', 'https://push.local/fully-stale', 'p', 'a', now() - interval '200 days');

INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth, updated_at)
VALUES ('00000000-0000-4000-8000-000000000301', 'https://push.local/stale-in-flight', 'p', 'a', now() - interval '200 days');

INSERT INTO public.notification_push_deliveries (notification_id, push_subscription_id, idempotency_key, status, claimed_at)
SELECT n.id, ps.id, 'hygiene-in-flight-fixture', 'processing', timezone('utc', now())
FROM public.notifications n
JOIN public.push_subscriptions ps ON ps.endpoint = 'https://push.local/stale-in-flight'
WHERE n.recipient_profile_id = '00000000-0000-4000-8000-000000000301'
  AND n.actor_profile_id = '00000000-0000-4000-8000-000000000305';

SET LOCAL ROLE service_role;
SELECT is(
  public.cleanup_stale_push_subscriptions(90),
  1,
  'cleanup deletes exactly subscriptions inactive on both client and server liveness'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.push_subscriptions WHERE endpoint = 'https://push.local/stale-but-delivered'
  ),
  'recently delivered subscriptions survive even with an untouched updated_at'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.push_subscriptions WHERE endpoint = 'https://push.local/stale-in-flight'
  ),
  'subscriptions holding an unexpired send lease are never deleted mid-send'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM public.push_subscriptions WHERE endpoint = 'https://push.local/fully-stale'
  ),
  'fully stale subscriptions are removed by the scheduled cleanup'
);

SELECT throws_ok(
  $$SELECT public.cleanup_stale_push_subscriptions(7)$$,
  'P0001',
  'invalid_stale_days',
  'stale_days below the lower bound is rejected'
);

SELECT throws_ok(
  $$SELECT public.cleanup_stale_push_subscriptions(NULL)$$,
  'P0001',
  'invalid_stale_days',
  'null stale_days is rejected'
);

SELECT * FROM finish();
ROLLBACK;
