BEGIN;

SELECT plan(29);

-- Structural contracts -------------------------------------------------------

SELECT ok(
  EXISTS (
    SELECT 1
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'push_subscriptions'
       AND column_name = 'owner_generation'
       AND is_nullable = 'NO'
       AND column_default = '0'
  ),
  'owner_generation exists as a non-nullable column defaulting to zero'
);

SELECT ok(
  (SELECT p.prosecdef
   FROM pg_proc p
   WHERE p.oid = 'public.settle_push_delivery(uuid,timestamptz,integer,integer,uuid,text,text,timestamptz,timestamptz,timestamptz)'::regprocedure),
  'settle RPC is security definer'
);

SELECT ok(
  (SELECT p.proconfig @> ARRAY['search_path=public, extensions']
   FROM pg_proc p
   WHERE p.oid = 'public.settle_push_delivery(uuid,timestamptz,integer,integer,uuid,text,text,timestamptz,timestamptz,timestamptz)'::regprocedure),
  'settle RPC fixes its search path'
);

SELECT ok(
  has_function_privilege('service_role', 'public.settle_push_delivery(uuid,timestamptz,integer,integer,uuid,text,text,timestamptz,timestamptz,timestamptz)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.settle_push_delivery(uuid,timestamptz,integer,integer,uuid,text,text,timestamptz,timestamptz,timestamptz)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.settle_push_delivery(uuid,timestamptz,integer,integer,uuid,text,text,timestamptz,timestamptz,timestamptz)', 'EXECUTE'),
  'only the service role may execute the settle RPC'
);

SELECT ok(
  EXISTS (
    SELECT 1
      FROM pg_proc p
     WHERE p.oid = 'public.claim_notification_push_deliveries(integer,timestamptz,boolean)'::regprocedure
       AND (SELECT array_agg(t.proname ORDER BY t.ordinality)
              FROM unnest(p.proargnames) WITH ORDINALITY AS t(proname, ordinality))
             @> ARRAY['p_return_lease_context', 'claimed_at', 'owner_generation']
  ),
  'the extended claim overload exposes the lease context fields'
);

SELECT is(
  (SELECT count(*)::integer FROM pg_proc p
   WHERE p.oid = 'public.claim_notification_push_deliveries(integer,timestamptz)'::regprocedure
     AND has_function_privilege('service_role', p.oid, 'EXECUTE')
     AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  1,
  'the legacy two-argument claim overload keeps its deployed shape and grants'
);

-- Fixtures --------------------------------------------------------------------

INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT id, 'authenticated', 'authenticated', id::text || '@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()
FROM (
  VALUES
    ('00000000-0000-4000-8000-000000000401'::uuid),
    ('00000000-0000-4000-8000-000000000402'::uuid),
    ('00000000-0000-4000-8000-000000000403'::uuid),
    ('00000000-0000-4000-8000-000000000404'::uuid)
) AS users(id);

INSERT INTO public.profiles (id, display_name, external_social_links)
SELECT id, 'Fencing ' || right(id::text, 3), '[{"url":"https://local.test"}]'::jsonb
FROM auth.users;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000402', true);
SELECT lives_ok(
  $$SELECT public.subscribe_push_subscription(
    'https://push.local/f0', 'p256dh-f0', 'auth-f0'
  )$$,
  'legacy three-argument calls still resolve through the optional defaults'
);
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000401', true);
SELECT public.subscribe_push_subscription(
  'https://push.local/f1', 'p256dh-f1', 'auth-f1', 'UA-F1'
) AS sub_id
\gset fen_

RESET ROLE;
INSERT INTO public.notifications (recipient_profile_id, notification_type, title, actor_profile_id)
VALUES ('00000000-0000-4000-8000-000000000401', 'new_follow', 'Fencing follow', '00000000-0000-4000-8000-000000000402');

-- Claim returns the lease identity ---------------------------------------------

SELECT * FROM public.claim_notification_push_deliveries(25, '2026-08-27 10:00+00', TRUE) AS c
\gset fen_

SELECT is(
  :'fen_claimed_at'::timestamptz,
  '2026-08-27 10:00+00'::timestamptz,
  'claim returns the lease timestamp it stamped'
);

SELECT is(
  :'fen_owner_generation'::integer,
  0,
  'claim returns the subscription owner_generation observed at claim time'
);

SELECT is(
  :'fen_attempts'::integer,
  1,
  'claim returns the incremented attempts count'
);

-- Fenced success path -----------------------------------------------------------

SELECT is(
  public.settle_push_delivery(
    :'fen_delivery_id'::uuid, :'fen_claimed_at'::timestamptz, :'fen_attempts'::integer,
    :'fen_owner_generation'::integer, :'fen_push_subscription_id'::uuid,
    'sent', NULL, '2026-08-27 10:00:05+00', NULL, '2026-08-27 10:00:05+00'
  ),
  TRUE,
  'a worker holding lease and generation settles its result'
);

SELECT is(
  (SELECT status FROM public.notification_push_deliveries WHERE id = :'fen_delivery_id'::uuid),
  'sent',
  'settled delivery records the terminal sent state'
);

SELECT is(
  (SELECT sent_at FROM public.notification_push_deliveries WHERE id = :'fen_delivery_id'::uuid),
  '2026-08-27 10:00:05+00'::timestamptz,
  'settled delivery stamps sent_at'
);

-- Lease theft blocks stale write-backs -------------------------------------------

RESET ROLE;
INSERT INTO public.notifications (recipient_profile_id, notification_type, title, actor_profile_id)
VALUES ('00000000-0000-4000-8000-000000000401', 'new_follow', 'Fencing follow 2', '00000000-0000-4000-8000-000000000403');

SELECT * FROM public.claim_notification_push_deliveries(25, '2026-08-27 11:00+00', TRUE) AS c
\gset steal_

SELECT * FROM public.claim_notification_push_deliveries(25, '2026-08-27 11:07+00', TRUE) AS c
\gset thief_

SELECT ok(
  :'steal_delivery_id'::uuid = :'thief_delivery_id'::uuid
    AND :'steal_attempts'::integer < :'thief_attempts'::integer,
  'an expired lease is re-claimed with an incremented attempts count'
);

SELECT is(
  public.settle_push_delivery(
    :'steal_delivery_id'::uuid, :'steal_claimed_at'::timestamptz, :'steal_attempts'::integer,
    :'steal_owner_generation'::integer, :'steal_push_subscription_id'::uuid,
    'sent', NULL, '2026-08-27 11:06+00', NULL, '2026-08-27 11:06+00'
  ),
  FALSE,
  'the stale first lease cannot write back after the lease was stolen'
);

SELECT is(
  (SELECT status || ':' || attempts::text
   FROM public.notification_push_deliveries WHERE id = :'steal_delivery_id'::uuid),
  'processing:2',
  'the new lease keeps exclusive ownership of the delivery state'
);

-- Ownership generation mismatch blocks write-backs --------------------------------

RESET ROLE;
UPDATE public.push_subscriptions
   SET owner_generation = owner_generation + 1
 WHERE id = :'thief_push_subscription_id'::uuid;

SELECT is(
  public.settle_push_delivery(
    :'thief_delivery_id'::uuid, :'thief_claimed_at'::timestamptz, :'thief_attempts'::integer,
    :'thief_owner_generation'::integer, :'thief_push_subscription_id'::uuid,
    'dead_letter', 'provider_http_500', NULL, NULL, '2026-08-27 11:08+00'
  ),
  FALSE,
  'a generation mismatch between claim and write-back fences the update'
);

SELECT is(
  (SELECT status FROM public.notification_push_deliveries WHERE id = :'thief_delivery_id'::uuid),
  'processing',
  'generation-mismatched work stays untouched for the next claim cycle'
);

-- endpoint_invalid deletes atomically only on fencing success ---------------------

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000401', true);
SELECT public.subscribe_push_subscription(
  'https://push.local/f2', 'p256dh-f2', 'auth-f2', 'UA-F2'
) AS invalid_sub_id
\gset inv_

RESET ROLE;
INSERT INTO public.notifications (recipient_profile_id, notification_type, title, actor_profile_id)
VALUES ('00000000-0000-4000-8000-000000000401', 'new_follow', 'Fencing follow 3', '00000000-0000-4000-8000-000000000404');

-- Fan-out targets every subscription of the recipient; keep only the f2 copy
-- for this scenario so the claim below returns exactly one row.
DELETE FROM public.notification_push_deliveries
WHERE push_subscription_id = :'fen_sub_id'::uuid
  AND notification_id = (SELECT id FROM public.notifications WHERE title = 'Fencing follow 3');

SELECT * FROM public.claim_notification_push_deliveries(25, '2026-08-27 11:09+00', TRUE) AS c
\gset inv_

-- Simulate an ownership move racing the in-flight worker: the subscription's
-- generation changes AFTER the claim was taken.
UPDATE public.push_subscriptions
   SET owner_generation = owner_generation + 1
 WHERE id = :'inv_invalid_sub_id'::uuid;

SELECT is(
  public.settle_push_delivery(
    :'inv_delivery_id'::uuid, :'inv_claimed_at'::timestamptz, :'inv_attempts'::integer,
    :'inv_owner_generation'::integer, :'inv_push_subscription_id'::uuid,
    'endpoint_invalid', 'provider_http_404', NULL, NULL, '2026-08-27 11:10+00'
  ),
  FALSE,
  'a worker whose generation went stale cannot trigger the endpoint_invalid deletion'
);

SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions WHERE id = :'inv_invalid_sub_id'::uuid),
  1,
  'the subscription survives a failed fencing attempt on the invalid path'
);

SELECT is(
  (SELECT status FROM public.notification_push_deliveries WHERE id = :'inv_delivery_id'::uuid),
  'processing',
  'the fenced-off delivery stays with the current lease'
);

SELECT is(
  public.settle_push_delivery(
    :'inv_delivery_id'::uuid, :'inv_claimed_at'::timestamptz, :'inv_attempts'::integer,
    (SELECT owner_generation FROM public.push_subscriptions WHERE id = :'inv_push_subscription_id'::uuid),
    :'inv_push_subscription_id'::uuid,
    'endpoint_invalid', 'provider_http_410', NULL, NULL, '2026-08-27 11:11+00'
  ),
  TRUE,
  'the current lease holder settles endpoint_invalid'
);

SELECT is(
  (SELECT status FROM public.notification_push_deliveries WHERE id = :'inv_delivery_id'::uuid),
  'endpoint_invalid',
  'endpoint_invalid is recorded as the delivery terminal state'
);

SELECT is(
  (SELECT count(*)::integer FROM public.push_subscriptions WHERE id = :'inv_invalid_sub_id'::uuid),
  0,
  'the provider-revoked subscription is deleted in the same transaction'
);

SELECT is(
  (SELECT count(*)::integer FROM public.notification_push_deliveries WHERE id = :'inv_delivery_id'::uuid),
  1,
  'delivery rows survive the subscription delete as audit metadata'
);

-- refresh mode never acquires foreign subscriptions ---------------------------------

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000402', true);

SELECT is(
  public.subscribe_push_subscription(
    'https://push.local/f1', 'p256dh-f1', 'auth-f1', 'UA-F2', 'refresh'
  ),
  NULL,
  'session-start refresh reports not-owned as NULL instead of moving the row'
);

RESET ROLE;
SELECT is(
  (SELECT profile_id = '00000000-0000-4000-8000-000000000401'
   FROM public.push_subscriptions WHERE endpoint = 'https://push.local/f1'),
  TRUE,
  'refresh leaves the foreign subscription binding untouched'
);

-- standard move bumps the ownership generation --------------------------------------

RESET ROLE;
SELECT owner_generation AS pre_move_generation
FROM public.push_subscriptions WHERE endpoint = 'https://push.local/f1'
\gset fen_

-- The move-time defer guard reads the wall clock; sweep the synthetic-scenario
-- lease exactly like the production claim guard would.
UPDATE public.notification_push_deliveries
   SET status = 'cancelled',
       last_error_code = 'subscription_missing',
       updated_at = timezone('utc', now())
 WHERE push_subscription_id = :'fen_sub_id'::uuid
   AND status IN ('pending', 'processing');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000402', true);
SELECT public.subscribe_push_subscription(
  'https://push.local/f1', 'p256dh-f1', 'auth-f1', 'UA-F2'
) AS moved_id
\gset fen_

RESET ROLE;
SELECT is(
  (SELECT owner_generation FROM public.push_subscriptions WHERE id = :'fen_moved_id'::uuid),
  :'fen_pre_move_generation'::integer + 1,
  'a cross-profile move increments owner_generation in the same transaction'
);

SELECT throws_ok(
  $$SELECT public.subscribe_push_subscription(
    'https://push.local/new-endpoint', 'k', 'k', NULL, 'aggressive'
  )$$,
  'P0001',
  'invalid_subscription_payload',
  'unknown modes are rejected before any row is touched'
);

SELECT * FROM finish();
ROLLBACK;
