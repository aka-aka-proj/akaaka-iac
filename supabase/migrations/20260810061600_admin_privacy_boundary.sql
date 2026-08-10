-- Admin JWT is not a private-data read exception.
-- PostgreSQL owner/service_role can still bypass RLS; see ADR 010 for that boundary.

-- Keep platform admin privilege out of the business-role column.
UPDATE public.profiles SET role_status = 'general' WHERE role_status = 'admin';
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_role_status_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_role_status_check
  CHECK (role_status IN ('general', 'venue_pending', 'venue_approved'));

-- Profiles: admins may read only their own profile row, like any other user.
DROP POLICY IF EXISTS profiles_read_all ON public.profiles;
CREATE POLICY profiles_read_non_admin ON public.profiles
  FOR SELECT TO authenticated
  USING (COALESCE(auth.jwt() ->> 'role', '') <> 'admin');
CREATE POLICY profiles_read_self_admin ON public.profiles
  FOR SELECT TO authenticated
  USING ((select auth.uid()) = id AND (auth.jwt() ->> 'role') = 'admin');

-- Reports, issues and comments are private to the person who submitted them.
DROP POLICY IF EXISTS reports_read_owner ON public.reports;
CREATE POLICY reports_read_owner ON public.reports
  FOR SELECT TO authenticated
  USING ((select auth.uid()) = reporter_id);

DROP POLICY IF EXISTS issues_read_owner ON public.issues;
CREATE POLICY issues_read_owner ON public.issues
  FOR SELECT TO authenticated
  USING ((select auth.uid()) = reporter_id);

DROP POLICY IF EXISTS issues_update_admin ON public.issues;

DROP POLICY IF EXISTS issue_comments_read_members ON public.issue_comments;
CREATE POLICY issue_comments_read_members ON public.issue_comments
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.issues i
    WHERE i.id = issue_id AND i.reporter_id = (select auth.uid())
  ));

DROP POLICY IF EXISTS issue_comments_insert_auth ON public.issue_comments;
CREATE POLICY issue_comments_insert_reporter ON public.issue_comments
  FOR INSERT TO authenticated
  WITH CHECK (
    profile_id = (select auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.issues i
      WHERE i.id = issue_id AND i.reporter_id = (select auth.uid())
    )
  );

-- Audit records are visible only to the affected user. Admin actions remain auditable
-- without exposing the audit payload to the administrator through the Data API.
DROP POLICY IF EXISTS audit_logs_admin_read ON public.audit_logs;

-- Registration answers and registration rows do not get an admin exception.
DROP POLICY IF EXISTS registrations_read_self_host_admin ON public.event_registrations;
CREATE POLICY registrations_read_self_host ON public.event_registrations
  FOR SELECT TO authenticated
  USING (
    profile_id = (select auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.events e
      WHERE e.id = event_id AND e.creator_id = (select auth.uid())
    )
  );

DROP POLICY IF EXISTS reg_responses_read_self_host_admin ON public.event_registration_responses;
CREATE POLICY reg_responses_read_self_host ON public.event_registration_responses
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1
    FROM public.event_registrations er
    WHERE er.id = registration_id
      AND (
        er.profile_id = (select auth.uid())
        OR EXISTS (
          SELECT 1 FROM public.events e
          WHERE e.id = er.event_id AND e.creator_id = (select auth.uid())
        )
      )
  ));

-- Metadata-only moderation queue. It intentionally omits reporter identity and details.
CREATE OR REPLACE FUNCTION public.get_admin_report_queue()
RETURNS TABLE (
  id uuid,
  category text,
  status text,
  target_profile_id uuid,
  target_event_id uuid,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF (select auth.jwt() ->> 'role') <> 'admin' THEN
    RAISE EXCEPTION 'admin role required' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT r.id, r.category, r.status, r.target_profile_id, r.target_event_id, r.created_at
  FROM public.reports r
  WHERE r.status IN ('open', 'triaging')
  ORDER BY r.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_admin_report_queue() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_report_queue() TO authenticated;

-- Controlled backend write: merge moderation status without returning or selecting
-- the user's existing metadata to the admin caller.
CREATE OR REPLACE FUNCTION public.set_profile_moderation_status(target_id uuid, moderation_status text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF (select auth.jwt() ->> 'role') NOT IN ('admin', 'service_role') THEN
    RAISE EXCEPTION 'controlled backend required' USING errcode = '42501';
  END IF;

  UPDATE public.profiles
  SET metadata = jsonb_set(
    COALESCE(metadata, '{}'::jsonb),
    '{moderation_status}',
    to_jsonb(moderation_status),
    true
  )
  WHERE id = target_id;
END;
$$;

REVOKE ALL ON FUNCTION public.set_profile_moderation_status(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_profile_moderation_status(uuid, text) TO service_role;
