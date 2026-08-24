BEGIN;

SELECT plan(23);

-- Structural contracts -------------------------------------------------------

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.push_subscriptions'::regclass
      AND conname = 'push_subscriptions_endpoint_unique'
      AND contype = 'u'
  ),
  'endpoint has a global single-column unique constraint'
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
  (SELECT p.prosecdef
   FROM pg_proc p
   WHERE p.oid = 'public.subscribe_push_subscription(text,text,text,text)'::regprocedure),
  'subscribe RPC is security definer'
);

SELECT ok(
  (SELECT p.proconfig @> ARRAY['search_path=public, extensions']
   FROM pg_proc p
   WHERE p.oid = 'public.subscribe_push_subscription(text,text,text,text)'::regprocedure),
  'subscribe RPC fixes its search path'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.subscribe_push_subscription(text,text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.subscribe_push_subscription(text,text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.subscribe_push_subscription(text,text,text,text)', 'EXECUTE'),
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

-- Behavioral contracts -------------------------------------------------------

INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT id, 'authenticated', 'authenticated', id::text || '@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()
FROM (
  VALUES
    ('00000000-0000-4000-8000-000000000301'::uuid),
    ('00000000-0000-4000-8000-000000000302'::uuid)
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
\gset hygiene_

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000302', true);
SELECT public.subscribe_push_subscription(
  'https://push.local/e1', 'p256dh-b', 'auth-b', 'UA-B'
) AS transferred_id
\gset hygiene_

SELECT is(
  :'hygiene_transferred_id'::uuid,
  :'hygiene_original_id'::uuid,
  'cross-profile takeover moves the same subscription row instead of duplicating it'
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

SELECT throws_ok(
  $$INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth)
    VALUES (
      '00000000-0000-4000-8000-000000000301',
      'https://push.local/e1',
      'p256dh-x',
      'auth-x'
    )$$,
  '23505',
  NULL,
  'direct client INSERT cannot bind an endpoint owned by another profile'
);

SELECT throws_ok(
  $$SELECT public.subscribe_push_subscription('https://push.local/e2', '   ', 'auth-ok', NULL)$$,
  'P0001',
  'invalid_subscription_payload',
  'blank subscription keys are rejected'
);

RESET ROLE;
SET LOCAL ROLE anon;
SELECT throws_ok(
  $$SELECT public.subscribe_push_subscription('https://push.local/e3', 'p', 'a', NULL)$$,
  '42501',
  NULL,
  'anon may not execute the subscribe RPC'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT throws_ok(
  $$SELECT public.subscribe_push_subscription('https://push.local/e3', 'p', 'a', NULL)$$,
  'P0001',
  'unauthenticated',
  'requests without a JWT subject are rejected'
);

-- Cleanup behaviour ----------------------------------------------------------

RESET ROLE;
SET LOCAL ROLE postgres;
INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth, updated_at)
VALUES
  ('00000000-0000-4000-8000-000000000301', 'https://push.local/stale-1', 'p', 'a', now() - interval '200 days'),
  ('00000000-0000-4000-8000-000000000301', 'https://push.local/stale-2', 'p', 'a', now() - interval '91 days'),
  ('00000000-0000-4000-8000-000000000301', 'https://push.local/fresh', 'p', 'a', now());

SET LOCAL ROLE service_role;
SELECT is(
  public.cleanup_stale_push_subscriptions(90),
  2,
  'cleanup deletes exactly the subscriptions past the staleness threshold'
);

SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions WHERE endpoint LIKE 'https://push.local/stale-%'),
  0,
  'stale subscriptions are removed by the scheduled cleanup'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.push_subscriptions WHERE endpoint = 'https://push.local/fresh'
  ),
  'fresh subscriptions survive the scheduled cleanup'
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
