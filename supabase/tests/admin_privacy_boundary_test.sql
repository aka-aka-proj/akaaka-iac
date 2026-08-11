BEGIN;

SELECT plan(23);

-- This suite deliberately checks the deployed migration contract only. It does
-- not insert user content, use production identities, or claim to replace the
-- hosted regular-user/admin behavioral matrix.
SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.profiles'::regclass),
  'profiles keeps RLS enabled'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'profiles'
      AND policyname = 'profiles_read_self_admin'
      AND qual LIKE '%auth.uid%'
  ),
  'admin profile read policy is self-scoped'
);

SELECT is(
  (SELECT count(*)::int FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'profiles'
     AND policyname = 'profiles_read_all'),
  0,
  'legacy admin/all profile read policy is absent'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'reports'
      AND policyname = 'reports_read_owner'
      AND qual LIKE '%reporter_id%'
      AND qual NOT LIKE '%role%admin%'
  ),
  'reports read policy is owner-scoped without admin exception'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'issues'
      AND policyname = 'issues_read_owner'
      AND qual LIKE '%reporter_id%'
      AND qual NOT LIKE '%role%admin%'
  ),
  'issues read policy is owner-scoped without admin exception'
);

SELECT is(
  (SELECT count(*)::int FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'issues'
     AND policyname = 'issues_update_admin'),
  1,
  'controlled admin issue moderation mutation remains available'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'issues'
      AND policyname = 'issues_update_admin'
      AND qual LIKE '%aal%aal2%'
      AND with_check LIKE '%aal%aal2%'
  ),
  'admin issue moderation mutation requires aal2'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'issue_comments'
      AND policyname = 'issue_comments_read_members'
      AND qual LIKE '%reporter_id%'
      AND qual NOT LIKE '%role%admin%'
  ),
  'issue comments read policy is reporter-scoped without admin exception'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'event_registrations'
      AND policyname = 'registrations_read_self_host'
      AND qual NOT LIKE '%role%admin%'
  ),
  'registration read policy has no admin exception'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'event_registration_responses'
      AND policyname = 'reg_responses_read_self_host'
      AND qual NOT LIKE '%role%admin%'
  ),
  'registration response read policy has no admin exception'
);

SELECT is(
  (SELECT count(*)::int FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'audit_logs'
     AND policyname = 'audit_logs_admin_read'),
  0,
  'legacy admin audit payload read policy is absent'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'get_admin_report_queue'
      AND p.prosecdef
      AND p.proconfig @> ARRAY['search_path=public, pg_temp']
  ),
  'moderation queue is a fixed-search-path security-definer function'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.get_admin_report_queue()', 'EXECUTE'),
  'authenticated can invoke the guarded moderation queue function'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.get_admin_report_queue()', 'EXECUTE'),
  'anonymous role cannot invoke the moderation queue function'
);

SELECT ok(
  NOT has_function_privilege('authenticated', 'public.set_profile_moderation_status(uuid, text)', 'EXECUTE'),
  'authenticated role cannot invoke the controlled moderation mutation'
);

SELECT ok(
  has_function_privilege('service_role', 'public.set_profile_moderation_status(uuid, text)', 'EXECUTE'),
  'service role retains the controlled moderation mutation grant'
);

SELECT ok(
  (SELECT prokind = 'f' FROM pg_proc WHERE oid = 'public.get_admin_report_queue()'::regprocedure),
  'moderation queue remains a function contract'
);

SELECT ok(
  pg_get_functiondef('public.get_admin_report_queue()'::regprocedure) LIKE '%app_metadata%'
    AND pg_get_functiondef('public.get_admin_report_queue()'::regprocedure) NOT LIKE '%auth.jwt() ->> ''role''%'
    AND pg_get_functiondef('public.get_admin_report_queue()'::regprocedure) LIKE '%aal%aal2%',
  'moderation queue checks app_metadata admin claim and aal2'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'moderation_actions'
      AND policyname = 'moderation_actions_admin_rw'
      AND qual LIKE '%app_metadata%'
      AND qual LIKE '%aal%aal2%'
      AND with_check LIKE '%app_metadata%'
      AND with_check LIKE '%aal%aal2%'
  ),
  'moderation action policy checks app_metadata admin claim and aal2'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_proc
    WHERE oid = 'public.get_admin_report_queue()'::regprocedure
      AND pg_get_function_result(oid) LIKE '%target_profile_id%'
      AND pg_get_function_result(oid) NOT LIKE '%details%'
      AND pg_get_function_result(oid) NOT LIKE '%reporter_id%'
  ),
  'moderation queue result is metadata-only and omits private report fields'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_proc
    WHERE oid = 'public.search_events(text, text, text, text, uuid, integer, integer)'::regprocedure
      AND NOT prosecdef
  ),
  'event search remains security invoker'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.search_events(text, text, text, text, uuid, integer, integer)', 'EXECUTE'),
  'anonymous role cannot invoke server-side event search'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.search_events(text, text, text, text, uuid, integer, integer)', 'EXECUTE'),
  'authenticated role can invoke server-side event search under RLS'
);

SELECT * FROM finish();
ROLLBACK;
