-- Enforce the high-risk admin MFA assurance contract at the database boundary.
-- The service-role controlled backend remains the only exception for operations
-- that are intentionally not exposed to browser clients.

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
  IF (select auth.jwt() ->> 'role') <> 'admin'
     OR COALESCE((select auth.jwt() ->> 'aal'), 'aal1') <> 'aal2' THEN
    RAISE EXCEPTION 'admin aal2 assurance required' USING errcode = '42501';
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

DROP POLICY IF EXISTS moderation_actions_admin_rw ON public.moderation_actions;
CREATE POLICY moderation_actions_admin_rw ON public.moderation_actions
  FOR ALL TO authenticated
  USING (
    (select auth.jwt() ->> 'role') = 'admin'
    AND (select auth.jwt() ->> 'aal') = 'aal2'
  )
  WITH CHECK (
    (select auth.jwt() ->> 'role') = 'admin'
    AND (select auth.jwt() ->> 'aal') = 'aal2'
  );

DROP POLICY IF EXISTS issues_update_admin ON public.issues;
CREATE POLICY issues_update_admin ON public.issues
  FOR UPDATE TO authenticated
  USING (
    (select auth.jwt() ->> 'role') = 'admin'
    AND (select auth.jwt() ->> 'aal') = 'aal2'
  )
  WITH CHECK (
    (select auth.jwt() ->> 'role') = 'admin'
    AND (select auth.jwt() ->> 'aal') = 'aal2'
  );
