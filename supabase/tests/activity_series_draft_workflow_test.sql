BEGIN;

SELECT plan(7);

SELECT has_table('public', 'event_series', 'event_series exists');
SELECT has_function('public', 'publish_event_series', ARRAY['uuid'], 'publish_event_series exists');

SELECT policy_func IS NOT NULL AS policy_exists
FROM (
  SELECT pg_get_expr(polwithcheck, polrelid) AS policy_func
  FROM pg_policy
  WHERE polrelid = 'public.event_series'::regclass
    AND polname = 'event_series_owner_insert'
) policy_check;

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_policy
    WHERE polrelid = 'public.event_series'::regclass
      AND polname = 'event_series_owner_insert'
      AND pg_get_expr(polwithcheck, polrelid) LIKE '%lifecycle_status%draft%'
  ),
  'series insert policy requires draft lifecycle'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_policy
    WHERE polrelid = 'public.event_series_membership'::regclass
      AND polname = 'event_series_membership_insert'
      AND pg_get_expr(polwithcheck, polrelid) LIKE '%lifecycle_status%draft%'
  ),
  'membership insert policy requires draft event and series'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE oid = 'public.publish_event_series(uuid)'::regprocedure
      AND prosecdef
  ),
  'publish function is security definer'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.publish_event_series(uuid)', 'EXECUTE'),
  'authenticated can execute publish function'
);

SELECT * FROM finish();
ROLLBACK;
