BEGIN;

-- api/004 §Acceptance tests: controlled revocation RPC, deletion tombstones,
-- cleanup marker write-in, and refresh-mode passive rebuild gating (#100).
--
-- Role discipline: actions run as the acting identity; every verification
-- read runs as the reset superuser, because push_subscriptions RLS hides
-- foreign rows and the deletion log is invisible to browser roles by design.

SELECT plan(63);

-- Structural contracts -------------------------------------------------------

SELECT ok(
  to_regclass('public.push_subscriptions_deletion_log') IS NOT NULL,
  'deletion log table exists'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.push_subscriptions_deletion_log'::regclass
      AND conname = 'push_subscriptions_deletion_log_pkey'
      AND contype = 'p'
  ),
  'endpoint is the tombstone primary key'
);

SELECT ok(
  (SELECT pg_get_constraintdef(c.oid) LIKE '%scheduled_cleanup%'
     AND pg_get_constraintdef(c.oid) LIKE '%user_revoked%'
   FROM pg_constraint c
   WHERE c.conrelid = 'public.push_subscriptions_deletion_log'::regclass
     AND c.conname LIKE '%deletion_source%'),
  'deletion_source allows exactly the two contract values'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.push_subscriptions_deletion_log'::regclass
      AND conname = 'push_subscriptions_deletion_log_endpoint_not_blank'
  ),
  'endpoint not-blank check exists'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conrelid = 'public.push_subscriptions_deletion_log'::regclass
      AND c.contype = 'f'
      AND c.confrelid = 'public.profiles'::regclass
      AND c.confdeltype = 'c'
  ),
  'last_owner_profile_id references profiles with ON DELETE CASCADE'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'push_subscriptions_deletion_log'
      AND indexdef LIKE '%last_owner_profile_id%'
  ),
  'tombstone owner foreign key carries a support index for cascade deletes'
);

SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.push_subscriptions_deletion_log'::regclass),
  'RLS is enabled on the deletion log'
);

SELECT is(
  (SELECT count(*)::integer FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'push_subscriptions_deletion_log'),
  0,
  'deny-by-default: the deletion log has zero RLS policies'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.push_subscriptions_deletion_log', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.push_subscriptions_deletion_log', 'INSERT')
    AND NOT has_table_privilege('anon', 'public.push_subscriptions_deletion_log', 'UPDATE')
    AND NOT has_table_privilege('anon', 'public.push_subscriptions_deletion_log', 'DELETE')
    AND NOT has_table_privilege('authenticated', 'public.push_subscriptions_deletion_log', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.push_subscriptions_deletion_log', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.push_subscriptions_deletion_log', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.push_subscriptions_deletion_log', 'DELETE'),
  'browser roles hold no direct privilege on the deletion log'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.unsubscribe_push_subscription(text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.unsubscribe_push_subscription(text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.unsubscribe_push_subscription(text,text,text)', 'EXECUTE'),
  'only authenticated clients may execute the unsubscribe RPC'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.push_subscription_key_fingerprint(text,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.push_subscription_key_fingerprint(text,text)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.push_subscription_key_fingerprint(text,text)', 'EXECUTE'),
  'the key-material fingerprint helper stays definer-internal'
);

SELECT ok(
  (SELECT p.prosecdef
     AND p.proconfig @> ARRAY['search_path=public, extensions']
   FROM pg_proc p
   WHERE p.oid = 'public.unsubscribe_push_subscription(text,text,text)'::regprocedure),
  'unsubscribe RPC is security definer with a fixed search path'
);

SELECT ok(
  (SELECT p.prosecdef
     AND p.proconfig @> ARRAY['search_path=public, extensions']
   FROM pg_proc p
   WHERE p.oid = 'public.cleanup_stale_push_subscriptions(integer)'::regprocedure)
    AND has_function_privilege('service_role', 'public.cleanup_stale_push_subscriptions(integer)', 'EXECUTE'),
  'cleanup RPC keeps its definer shape and service_role-only execution'
);

-- Fixtures -------------------------------------------------------------------

INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT id, 'authenticated', 'authenticated', id::text || '@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()
FROM (
  VALUES
    ('00000000-0000-4000-8000-000000000401'::uuid),
    ('00000000-0000-4000-8000-000000000402'::uuid),
    ('00000000-0000-4000-8000-000000000403'::uuid)
) AS users(id);

INSERT INTO public.profiles (id, display_name, external_social_links)
SELECT id, 'Revoke ' || right(id::text, 3), '[{"url":"https://local.test"}]'::jsonb
FROM auth.users;

-- Behavioral contracts -------------------------------------------------------

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000401', true);

SELECT lives_ok(
  $$SELECT public.subscribe_push_subscription(
    'https://push.local/rev1', 'k1u', 'k1a', 'UA-1'
  )$$,
  'first profile subscribes a fresh endpoint through the RPC'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions WHERE endpoint = 'https://push.local/rev1'),
  1,
  'the subscription row exists before revocation attempts'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000401', true);
SELECT throws_ok(
  $$SELECT public.unsubscribe_push_subscription(
    'https://push.local/rev1', 'k1u', 'wrong-auth'
  )$$,
  'P0001',
  'endpoint_conflict',
  'own-row revocation with mismatched key material is rejected'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions WHERE endpoint = 'https://push.local/rev1'),
  1,
  'a failed possession proof leaves the binding untouched'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000402', true);
SELECT throws_ok(
  $$SELECT public.unsubscribe_push_subscription(
    'https://push.local/rev1', 'k1u', 'k1a'
  )$$,
  'P0001',
  'endpoint_conflict',
  'even stolen-valid keys cannot revoke another profile binding'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions WHERE endpoint = 'https://push.local/rev1'),
  1,
  'a non-owner revocation attempt leaves the binding untouched'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000401', true);
SELECT throws_ok(
  $$SELECT public.unsubscribe_push_subscription(
    'https://push.local/never-seen', 'ku', 'ka'
  )$$,
  'P0001',
  'endpoint_conflict',
  'revoking an endpoint with neither row nor tombstone is rejected'
);

SELECT throws_ok(
  $$SELECT public.unsubscribe_push_subscription(
    'https://push.local/rev1', 'k1u', '   '
  )$$,
  'P0001',
  'invalid_subscription_payload',
  'blank key material fails payload validation'
);

SELECT is(
  public.unsubscribe_push_subscription('https://push.local/rev1', 'k1u', 'k1a'),
  true,
  'owner revocation with matching keys succeeds'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions WHERE endpoint = 'https://push.local/rev1'),
  0,
  'the revoked binding is gone'
);

SELECT is(
  (SELECT deletion_source FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/rev1'),
  'user_revoked',
  'the tombstone records user revocation intent'
);

SELECT is(
  (SELECT last_owner_profile_id FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/rev1'),
  '00000000-0000-4000-8000-000000000401'::uuid,
  'the tombstone records the last owner'
);

SELECT is(
  (SELECT key_material_fingerprint FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/rev1'),
  (SELECT public.push_subscription_key_fingerprint('k1u', 'k1a')),
  'the tombstone stores the one-way fingerprint of the original key pair'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000401', true);
SELECT is(
  public.unsubscribe_push_subscription('https://push.local/rev1', 'k1u', 'k1a'),
  true,
  're-calling unsubscribe against the surviving marker stays idempotent'
);

RESET ROLE;
SELECT is(
  (SELECT deletion_source FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/rev1'),
  'user_revoked',
  'the idempotent re-call keeps the user_revoked marker'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000401', true);
SELECT ok(
  (SELECT public.subscribe_push_subscription(
    'https://push.local/rev1', 'k1u', 'k1a', NULL, 'refresh'
  ) IS NULL),
  'session refresh after explicit revocation never resurrects the binding'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions WHERE endpoint = 'https://push.local/rev1'),
  0,
  'no row was recreated behind the user_revoked marker'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000401', true);
SELECT ok(
  (SELECT public.subscribe_push_subscription(
    'https://push.local/brand-new-refresh-only', 'nu', 'na', NULL, 'refresh'
  ) IS NULL),
  'passive session refresh can never conjure a brand-new binding'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions
    WHERE endpoint = 'https://push.local/brand-new-refresh-only'),
  0,
  'the regression guard holds: refresh without a tombstone creates nothing'
);

-- Deferred revocation while a delivery send lease is active ------------------

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000401', true);
SELECT lives_ok(
  $$SELECT public.subscribe_push_subscription(
    'https://push.local/def1', 'du', 'da', 'UA-defer'
  )$$,
  'the deferral fixture endpoint starts as a live binding'
);

RESET ROLE;
INSERT INTO public.notifications (recipient_profile_id, notification_type, title, actor_profile_id)
VALUES ('00000000-0000-4000-8000-000000000401', 'new_follow', 'Defer follow', '00000000-0000-4000-8000-000000000402');

UPDATE public.notification_push_deliveries d
SET status = 'processing',
    claimed_at = timezone('utc', now())
FROM public.push_subscriptions ps
WHERE ps.endpoint = 'https://push.local/def1'
  AND d.push_subscription_id = ps.id;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000401', true);
SELECT throws_ok(
  $$SELECT public.unsubscribe_push_subscription(
    'https://push.local/def1', 'du', 'da'
  )$$,
  'P0001',
  'revocation_deferred',
  'revocation is deferred while an unexpired delivery send lease is active'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions WHERE endpoint = 'https://push.local/def1'),
  1,
  'a deferred revocation leaves the binding in place'
);

SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/def1'),
  0,
  'a deferred revocation writes no tombstone'
);

UPDATE public.notification_push_deliveries d
SET claimed_at = timezone('utc', now()) - interval '10 minutes'
FROM public.push_subscriptions ps
WHERE ps.endpoint = 'https://push.local/def1'
  AND d.push_subscription_id = ps.id;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000401', true);
SELECT is(
  public.unsubscribe_push_subscription('https://push.local/def1', 'du', 'da'),
  true,
  'revocation succeeds once the send lease has expired'
);

RESET ROLE;
SELECT is(
  (SELECT deletion_source FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/def1'),
  'user_revoked',
  'the post-deferral revocation records user revocation intent'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000402', true);
SELECT ok(
  (SELECT public.subscribe_push_subscription(
    'https://push.local/rev1', 'k1u', 'k1a', 'UA-2'
  ) IS NOT NULL),
  'explicit standard-mode enablement binds the unowned endpoint'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/rev1'),
  0,
  'any successful bind retires the residual tombstone'
);

SELECT is(
  (SELECT profile_id FROM public.push_subscriptions WHERE endpoint = 'https://push.local/rev1'),
  '00000000-0000-4000-8000-000000000402'::uuid,
  'the fresh binding belongs to the explicitly enabling profile'
);

INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth, updated_at)
VALUES ('00000000-0000-4000-8000-000000000403', 'https://push.local/clean2', 'k2u', 'k2a',
        timezone('utc', now()) - interval '400 days');

SET LOCAL ROLE service_role;
SELECT is(
  public.cleanup_stale_push_subscriptions(90),
  1,
  'cleanup removes the fully stale subscription'
);

RESET ROLE;
SELECT is(
  (SELECT deletion_source FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/clean2'),
  'scheduled_cleanup',
  'cleanup records its own tombstone source in the same transaction'
);

SELECT is(
  (SELECT last_owner_profile_id FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/clean2'),
  '00000000-0000-4000-8000-000000000403'::uuid,
  'the cleanup tombstone preserves the last owner for rebuild gating'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000403', true);
SELECT ok(
  (SELECT public.subscribe_push_subscription(
    'https://push.local/clean2', 'k2u', 'k2a', NULL, 'refresh'
  ) IS NOT NULL),
  'the proven last owner rebuilds a cleaned-up binding via passive refresh'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions
    WHERE endpoint = 'https://push.local/clean2'),
  1,
  'exactly one rebuilt binding exists'
);

SELECT is(
  (SELECT profile_id FROM public.push_subscriptions WHERE endpoint = 'https://push.local/clean2'),
  '00000000-0000-4000-8000-000000000403'::uuid,
  'the rebuilt binding belongs to the original owner'
);

SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/clean2'),
  0,
  'a successful rebuild removes the tombstone in the same transaction'
);

INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth, updated_at)
VALUES ('00000000-0000-4000-8000-000000000401', 'https://push.local/clean3', 'k3u', 'k3a',
        timezone('utc', now()) - interval '400 days');

SET LOCAL ROLE service_role;
SELECT is(
  public.cleanup_stale_push_subscriptions(90),
  1,
  'the second stale subscription is removed with its marker'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000401', true);
SELECT ok(
  (SELECT public.subscribe_push_subscription(
    'https://push.local/clean3', 'rotated-u', 'rotated-a', NULL, 'refresh'
  ) IS NULL),
  'refresh with rotated key material cannot prove possession of the old binding'
);

RESET ROLE;
SELECT is(
  (SELECT deletion_source FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/clean3'),
  'scheduled_cleanup',
  'a failed rebuild attempt leaves the cleanup marker intact'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000402', true);
SELECT ok(
  (SELECT public.subscribe_push_subscription(
    'https://push.local/clean3', 'k3u', 'k3a', NULL, 'refresh'
  ) IS NULL),
  'refresh by a non-owner with fully valid original keys stays passive'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/clean3'),
  1,
  'the rejected non-owner attempt consumes nothing'
);

SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions
    WHERE endpoint = 'https://push.local/clean3'),
  0,
  'no binding was recreated by any passive rejection path'
);

-- Cleanup never overwrites a residual user_revoked marker --------------------

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000403', true);
SELECT lives_ok(
  $$SELECT public.subscribe_push_subscription(
    'https://push.local/guarded', 'gu', 'ga', 'UA-guard'
  )$$,
  'the guarded endpoint starts as a live binding'
);

SELECT is(
  public.unsubscribe_push_subscription('https://push.local/guarded', 'gu', 'ga'),
  true,
  'the owner revokes the guarded endpoint, leaving a user_revoked marker'
);

RESET ROLE;
INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth, updated_at)
VALUES ('00000000-0000-4000-8000-000000000403', 'https://push.local/guarded', 'gu2', 'ga2',
        timezone('utc', now()) - interval '400 days');

SELECT is(
  (SELECT deletion_source FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/guarded'),
  'user_revoked',
  'a legacy direct-INSERT rebuild coexists with the surviving marker'
);

SET LOCAL ROLE service_role;
SELECT is(
  public.cleanup_stale_push_subscriptions(90),
  1,
  'cleanup deletes the rebuilt stale row while keeping the protected marker'
);

RESET ROLE;
SELECT is(
  (SELECT deletion_source FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/guarded'),
  'user_revoked',
  'cleanup does not overwrite a residual user_revoked marker'
);

SELECT is(
  (SELECT last_owner_profile_id FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/guarded'),
  '00000000-0000-4000-8000-000000000403'::uuid,
  'the protected marker keeps its original owner'
);

SELECT is(
  (SELECT key_material_fingerprint FROM public.push_subscriptions_deletion_log
    WHERE endpoint = 'https://push.local/guarded'),
  (SELECT public.push_subscription_key_fingerprint('gu', 'ga')),
  'the protected marker keeps its original key fingerprint'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM public.push_subscriptions
     WHERE endpoint = 'https://push.local/guarded'
  ),
  'the stale rebuilt row itself was still deleted'
);

SET LOCAL ROLE service_role;
SELECT throws_ok(
  $$SELECT public.cleanup_stale_push_subscriptions(10)$$,
  'P0001',
  'invalid_stale_days',
  'stale_days below the lower bound is still rejected'
);

SELECT * FROM finish();
ROLLBACK;
