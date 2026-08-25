-- Contract-step assertions for the global endpoint unique constraint and the
-- INSERT revocation (aka-aka-proj/akaaka-iac#87, #93; api/004 §Rollout
-- ordering step 3, Phase A). UPDATE/DELETE retention is pinned here on
-- purpose: their revocation is gated on replacements landing first
-- (p_mode refresh RPC / unsubscribe_push_subscription + deletion log).

BEGIN;

SELECT plan(13);

-- Schema contracts ------------------------------------------------------------

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.push_subscriptions'::regclass
      AND conname = 'push_subscriptions_endpoint_unique'
      AND contype = 'u'
  ),
  'global unique constraint on endpoint exists'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.push_subscriptions'::regclass
      AND conname = 'push_subscriptions_endpoint_unique'
      AND convalidated
  ),
  'the global unique constraint is validated against existing rows'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.push_subscriptions'::regclass
      AND contype = 'u'
      AND pg_get_constraintdef(oid) LIKE '%UNIQUE (profile_id, endpoint)%'
  ),
  'legacy composite UNIQUE(profile_id, endpoint) remains as compatibility layer'
);

-- Uniqueness behavior ---------------------------------------------------------

INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT id, 'authenticated', 'authenticated', id::text || '@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()
FROM (
  VALUES
    ('00000000-0000-4000-8000-000000000401'::uuid),
    ('00000000-0000-4000-8000-000000000402'::uuid)
) AS users(id);

INSERT INTO public.profiles (id, display_name, external_social_links)
SELECT id, 'ContractStep ' || right(id::text, 3), '[{"url":"https://local.test"}]'::jsonb
FROM auth.users;

SELECT lives_ok(
  $$INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth)
    VALUES (
      '00000000-0000-4000-8000-000000000401',
      'https://push.local/cs-shared',
      'p256dh-cs1',
      'auth-cs1'
    )$$,
  'first subscription for an endpoint is accepted'
);

SELECT throws_ok(
  $$INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth)
    VALUES (
      '00000000-0000-4000-8000-000000000402',
      'https://push.local/cs-shared',
      'p256dh-cs2',
      'auth-cs2'
    )$$,
  '23505',
  NULL,
  'a second profile binding the same endpoint violates the global unique constraint'
);

SELECT lives_ok(
  $$INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth)
    VALUES (
      '00000000-0000-4000-8000-000000000402',
      'https://push.local/cs-unique',
      'p256dh-cs3',
      'auth-cs3'
    )$$,
  'distinct endpoints under one profile remain allowed by the composite contract'
);

SELECT throws_ok(
  $$INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth)
    VALUES (
      '00000000-0000-4000-8000-000000000402',
      '   ',
      'p256dh-cs4',
      'auth-cs4'
    )$$,
  '23514',
  NULL,
  'not-blank CHECK keeps rejecting blank endpoints alongside the new constraint'
);

-- Privilege contracts (Phase A) -----------------------------------------------

SELECT ok(
  NOT has_table_privilege('authenticated', 'public.push_subscriptions', 'INSERT'),
  'contract-step revokes direct client INSERT'
);

SELECT ok(
  has_table_privilege('authenticated', 'public.push_subscriptions', 'SELECT'),
  'authenticated clients keep RLS-scoped self reads'
);

SELECT ok(
  has_table_privilege('authenticated', 'public.push_subscriptions', 'UPDATE')
    AND has_table_privilege('authenticated', 'public.push_subscriptions', 'DELETE'),
  'UPDATE/DELETE stay open until p_mode refresh RPC and unsubscribe RPC land'
);

SELECT ok(
  has_table_privilege('service_role', 'public.push_subscriptions', 'INSERT')
    AND has_table_privilege('service_role', 'public.push_subscriptions', 'UPDATE')
    AND has_table_privilege('service_role', 'public.push_subscriptions', 'DELETE'),
  'the service-side worker keeps full subscription access'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000401', true);

SELECT throws_ok(
  $$INSERT INTO public.push_subscriptions (profile_id, endpoint, p256dh, auth)
    VALUES (
      '00000000-0000-4000-8000-000000000401',
      'https://push.local/cs-denied',
      'p256dh-cs5',
      'auth-cs5'
    )$$,
  '42501',
  NULL,
  'direct client INSERT fails with permission denied even for the row owner'
);

RESET ROLE;

-- Post-migration invariants ---------------------------------------------------

SELECT is(
  (
    SELECT count(*)
    FROM (
      SELECT endpoint
      FROM public.push_subscriptions
      GROUP BY endpoint
      HAVING count(*) > 1
    ) duplicates
  ),
  0::bigint,
  'no duplicate endpoints survive the migration'
);

SELECT * FROM finish();
ROLLBACK;
