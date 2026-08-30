BEGIN;

SELECT plan(7);

SELECT ok(
  (SELECT p.prosecdef
   FROM pg_proc p
   WHERE p.oid = 'public.set_event_publication(uuid, text, timestamptz, timestamptz)'::regprocedure),
  'publication resolver is security definer'
);

SELECT ok(
  (SELECT p.proconfig @> ARRAY['search_path=public, extensions']
   FROM pg_proc p
   WHERE p.oid = 'public.set_event_publication(uuid, text, timestamptz, timestamptz)'::regprocedure),
  'publication resolver fixes its search path'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.set_event_publication(uuid, text, timestamptz, timestamptz)', 'EXECUTE'),
  'owners call the publication resolver as authenticated users'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.set_event_publication(uuid, text, timestamptz, timestamptz)', 'EXECUTE'),
  'anonymous callers cannot execute the publication resolver'
);

SELECT ok(
  pg_get_functiondef('public.set_event_publication(uuid, text, timestamptz, timestamptz)'::regprocedure)
    LIKE '%draft events cannot have publication schedules%'
  AND pg_get_functiondef('public.set_event_publication(uuid, text, timestamptz, timestamptz)'::regprocedure)
    LIKE '%p_publish_at IS NOT NULL OR p_unpublish_at IS NOT NULL%',
  'publication resolver rejects schedule times on drafts'
);

SELECT ok(
  pg_get_functiondef('public.set_event_publication(uuid, text, timestamptz, timestamptz)'::regprocedure)
    LIKE '%lifecycle_status = ''draft''%',
  'draft guard keys on lifecycle_status'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM public.events
    WHERE lifecycle_status = 'draft'
      AND (publish_at IS NOT NULL OR unpublish_at IS NOT NULL)
  ),
  'no draft event carries a dead publication schedule'
);

SELECT * FROM finish();
ROLLBACK;
