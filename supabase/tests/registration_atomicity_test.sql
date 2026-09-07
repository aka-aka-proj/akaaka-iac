BEGIN;

SELECT plan(8);

SELECT ok(
  to_regprocedure('public.create_event_registration_atomic(uuid,uuid)') IS NOT NULL,
  'single-event registration uses a database RPC'
);

SELECT ok(
  pg_get_functiondef('public.create_event_registration_atomic(uuid,uuid)'::regprocedure)
    LIKE '%FOR UPDATE%'
    AND pg_get_functiondef('public.create_event_registration_atomic(uuid,uuid)'::regprocedure)
      LIKE '%event_registrations%'
    AND pg_get_functiondef('public.create_event_registration_atomic(uuid,uuid)'::regprocedure)
      LIKE '%max_capacity%',
  'single-event RPC locks before recounting capacity'
);

SELECT ok(
  pg_get_functiondef('public.register_event_series_atomic(uuid,uuid,jsonb,uuid[])'::regprocedure)
    LIKE '%p_expected_event_ids%'
    AND pg_get_functiondef('public.register_event_series_atomic(uuid,uuid,jsonb,uuid[])'::regprocedure)
      LIKE '%IS DISTINCT FROM%',
  'series RPC validates the membership snapshot inside the transaction'
);

SELECT ok(
  pg_get_functiondef('public.register_event_series_atomic(uuid,uuid,jsonb,uuid[])'::regprocedure)
    LIKE '%FOR UPDATE OF e, esm%',
  'series RPC locks membership and event rows'
);

SELECT ok(
  has_function_privilege('service_role', 'public.create_event_registration_atomic(uuid,uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.create_event_registration_atomic(uuid,uuid)', 'EXECUTE'),
  'single-event atomic RPC is service-role only'
);

SELECT ok(
  has_function_privilege('service_role', 'public.register_event_series_atomic(uuid,uuid,jsonb,uuid[])', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.register_event_series_atomic(uuid,uuid,jsonb,uuid[])', 'EXECUTE'),
  'series atomic RPC is service-role only'
);

SELECT ok(
  pg_get_functiondef('public.create_event_registration_atomic(uuid,uuid)'::regprocedure)
    LIKE '%status IN (''approved'', ''pending'')%',
  'single-event capacity count preserves approved and pending semantics'
);

SELECT ok(
  pg_get_functiondef('public.create_event_registration_atomic(uuid,uuid)'::regprocedure)
    LIKE '%RETURNING er.id, er.event_id, er.status%',
  'single-event RPC qualifies RETURNING columns against its table alias'
);

SELECT * FROM finish();
ROLLBACK;
