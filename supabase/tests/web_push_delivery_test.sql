BEGIN;

SELECT plan(10);

SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.notification_push_deliveries'::regclass),
  'delivery outbox keeps RLS enabled'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.notification_push_deliveries', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.notification_push_deliveries', 'SELECT'),
  'browser roles cannot read delivery metadata'
);

SELECT ok(
  has_table_privilege('service_role', 'public.notification_push_deliveries', 'SELECT')
    AND has_table_privilege('service_role', 'public.notification_push_deliveries', 'UPDATE'),
  'service role can claim and update delivery metadata'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.notifications'::regclass
      AND tgname = 'trg_enqueue_notification_push_deliveries'
      AND NOT tgenabled = 'D'
  ),
  'notification insert trigger enqueues outbox work'
);

SELECT ok(
  (SELECT p.prosecdef
   FROM pg_proc p
   WHERE p.oid = 'public.enqueue_notification_push_deliveries()'::regprocedure),
  'enqueue function is security definer for the notification trigger'
);

SELECT ok(
  (SELECT p.proconfig @> ARRAY['search_path=public, extensions']
   FROM pg_proc p
   WHERE p.oid = 'public.claim_notification_push_deliveries(integer,timestamptz)'::regprocedure),
  'claim function fixes its search path'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.claim_notification_push_deliveries(integer,timestamptz)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.claim_notification_push_deliveries(integer,timestamptz)', 'EXECUTE')
    AND has_function_privilege('service_role', 'public.claim_notification_push_deliveries(integer,timestamptz)', 'EXECUTE'),
  'only service role can claim delivery jobs'
);

SELECT ok(
  pg_get_functiondef('public.enqueue_notification_push_deliveries()'::regprocedure)
    NOT LIKE '%http%'
    AND pg_get_functiondef('public.enqueue_notification_push_deliveries()'::regprocedure)
      NOT LIKE '%pg_net%',
  'enqueue trigger does not call an external network provider'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.notification_push_deliveries'::regclass
      AND contype = 'u'
      AND conname = 'notification_push_deliveries_idempotency_key_key'
  ),
  'delivery jobs have a unique idempotency key'
);

SELECT ok(
  pg_get_functiondef('public.claim_notification_push_deliveries(integer,timestamptz)'::regprocedure)
    LIKE '%SKIP LOCKED%'
    AND pg_get_functiondef('public.claim_notification_push_deliveries(integer,timestamptz)'::regprocedure)
      LIKE '%processing%',
  'claim function uses a lease-aware locked claim path'
);

SELECT * FROM finish();
ROLLBACK;
