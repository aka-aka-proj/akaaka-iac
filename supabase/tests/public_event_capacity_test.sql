BEGIN;

SELECT plan(7);

SELECT ok(
  (SELECT p.prosecdef
   FROM pg_proc p
   WHERE p.oid = 'public.get_event_capacity(uuid)'::regprocedure),
  'capacity resolver is security definer'
);

SELECT ok(
  (SELECT p.proconfig @> ARRAY['search_path=public, extensions']
   FROM pg_proc p
   WHERE p.oid = 'public.get_event_capacity(uuid)'::regprocedure),
  'capacity resolver fixes its search path'
);

SELECT ok(
  has_function_privilege('anon', 'public.get_event_capacity(uuid)', 'EXECUTE'),
  'anonymous viewers can request a visible event capacity summary'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.get_event_capacity(uuid)', 'EXECUTE'),
  'authenticated viewers can request a visible event capacity summary'
);

SELECT ok(
  pg_get_function_result('public.get_event_capacity(uuid)'::regprocedure)
    = 'record',
  'capacity resolver returns a composite aggregate record'
);

SELECT ok(
  pg_get_functiondef('public.get_event_capacity(uuid)'::regprocedure)
    LIKE '%approved_registration_count%'
    AND pg_get_functiondef('public.get_event_capacity(uuid)'::regprocedure)
      LIKE '%capacity_external_guest_count%',
  'capacity resolver exposes only the two documented aggregate outputs'
);

SELECT ok(
  pg_get_functiondef('public.get_event_capacity(uuid)'::regprocedure)
    LIKE '%publication_status = ''published''%'
    AND pg_get_functiondef('public.get_event_capacity(uuid)'::regprocedure)
      LIKE '%visibility_settings%',
  'capacity resolver rechecks event publication and visibility'
);

SELECT * FROM finish();
ROLLBACK;
