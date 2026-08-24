BEGIN;

SELECT plan(5);

-- Contract suite for the event edit lock (docs/spec/features/events/003-event-edit-spec.md).
-- Checks the deployed events_update_owner policy shape; pg_policies stores
-- normalized SQL (NOT IN becomes <> ALL with explicit ::text casts), so the
-- patterns below match the deployed form. The hosted regular-user behavioral
-- matrix remains a staging validation concern.

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'events'
      AND policyname = 'events_update_owner'
      AND roles = '{authenticated}'
      AND cmd = 'UPDATE'
  ),
  'events_update_owner stays an owner-scoped UPDATE policy for authenticated'
);

SELECT is(
  (SELECT count(*)::int FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'events'
     AND policyname = 'events_update_owner'
     AND qual LIKE '%lifecycle_status <> ALL (ARRAY[%''completed''::text, ''archived''::text, ''cancelled''::text]%'
     AND qual LIKE '%(lifecycle_status = ''draft''::text) OR (start_time > timezone(''utc''::text, now()))%'),
  1,
  'USING excludes terminal lifecycle states and started non-draft events'
);

SELECT is(
  (SELECT count(*)::int FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'events'
     AND policyname = 'events_update_owner'
     AND with_check LIKE '%lifecycle_status <> ALL (ARRAY[%''completed''::text, ''archived''::text, ''cancelled''::text]%'
     AND with_check LIKE '%(lifecycle_status = ''draft''::text) OR (start_time > timezone(''utc''::text, now()))%'),
  1,
  'WITH CHECK mirrors both guards so edits cannot move start_time into the past'
);

SELECT is(
  (SELECT qual FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'events'
     AND policyname = 'events_update_owner'),
  (SELECT with_check FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'events'
     AND policyname = 'events_update_owner'),
  'USING and WITH CHECK stay symmetric'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'set_event_publication'
      AND p.prosecdef
  ),
  'publication control stays SECURITY DEFINER so hosts can still unpublish started events'
);

SELECT * FROM finish();
ROLLBACK;
