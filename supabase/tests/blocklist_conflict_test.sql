BEGIN;

SELECT plan(12);

SELECT has_table(
  'private', 'registration_blocklist_acknowledgements',
  'blocklist acknowledgements are transaction-scoped private state'
);

SELECT ok(
  to_regprocedure('public.create_event_registration_checked(uuid,uuid,boolean)') IS NOT NULL,
  'single-event checked registration RPC exists'
);

SELECT ok(
  to_regprocedure('public.register_event_series_checked(uuid,uuid,jsonb,uuid[],boolean)') IS NOT NULL,
  'series checked registration RPC exists'
);

SELECT ok(
  to_regprocedure('public.review_event_registration_checked(uuid,uuid,uuid,text,boolean)') IS NOT NULL,
  'checked organizer review RPC exists'
);

SELECT ok(
  has_function_privilege('service_role', 'public.create_event_registration_checked(uuid,uuid,boolean)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.create_event_registration_checked(uuid,uuid,boolean)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.create_event_registration_checked(uuid,uuid,boolean)', 'EXECUTE'),
  'single-event checked RPC is service-role only'
);

SELECT ok(
  has_function_privilege('service_role', 'public.register_event_series_checked(uuid,uuid,jsonb,uuid[],boolean)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.register_event_series_checked(uuid,uuid,jsonb,uuid[],boolean)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.register_event_series_checked(uuid,uuid,jsonb,uuid[],boolean)', 'EXECUTE'),
  'series checked RPC is service-role only'
);

SELECT ok(
  has_function_privilege('service_role', 'public.review_event_registration_checked(uuid,uuid,uuid,text,boolean)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.review_event_registration_checked(uuid,uuid,uuid,text,boolean)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.review_event_registration_checked(uuid,uuid,uuid,text,boolean)', 'EXECUTE'),
  'organizer review checked RPC is service-role only'
);

SELECT ok(
  NOT has_table_privilege('authenticated', 'private.registration_blocklist_acknowledgements', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'private.registration_blocklist_acknowledgements', 'INSERT')
    AND NOT has_table_privilege('anon', 'private.registration_blocklist_acknowledgements', 'SELECT')
    AND NOT has_table_privilege('anon', 'private.registration_blocklist_acknowledgements', 'INSERT'),
  'browser roles cannot access acknowledgement state'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_trigger t
    WHERE t.tgrelid = 'public.event_registrations'::regclass
      AND NOT t.tgisinternal
      AND pg_get_triggerdef(t.oid) ILIKE '%BEFORE%'
  ),
  'event registrations have a database-level pre-write enforcement trigger'
);

SELECT ok(
  pg_get_functiondef('public.create_event_registration_checked(uuid,uuid,boolean)'::regprocedure)
    LIKE '%FOR UPDATE%',
  'single-event checked RPC serializes against the event row'
);

SELECT ok(
  pg_get_functiondef('public.register_event_series_checked(uuid,uuid,jsonb,uuid[],boolean)'::regprocedure)
    LIKE '%p_expected_event_ids%'
    AND pg_get_functiondef('public.register_event_series_checked(uuid,uuid,jsonb,uuid[],boolean)'::regprocedure)
      LIKE '%IS DISTINCT FROM%',
  'series checked RPC fails closed on membership snapshot mismatch'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class r ON r.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE n.nspname = 'private'
      AND r.relname = 'registration_blocklist_acknowledgements'
      AND c.contype IN ('p','u')
  ),
  'acknowledgement state has a uniqueness boundary preventing unrestricted reuse'
);

SELECT * FROM finish();
ROLLBACK;
