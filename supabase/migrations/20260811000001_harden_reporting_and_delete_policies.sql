-- Harden the contracts carried forward from the documentation reorganisation.
-- This is a forward migration; it does not rewrite hosted migration history.

-- Profile rows are created before staged onboarding is complete. The onboarding
-- flow, not the row default, owns the minimum social-link requirement.
ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_social_links_min_one;

ALTER TABLE public.reports
  ADD COLUMN IF NOT EXISTS rejection_reason_code TEXT;

-- Preserve existing rejected records while making the new contract explicit.
UPDATE public.reports
SET rejection_reason_code = 'other'
WHERE status = 'rejected' AND rejection_reason_code IS NULL;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.reports
    WHERE (target_profile_id IS NOT NULL) = (target_event_id IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'reports contain rows without exactly one target';
  END IF;
END
$$;

ALTER TABLE public.reports
  DROP CONSTRAINT IF EXISTS reports_target_check,
  DROP CONSTRAINT IF EXISTS reports_target_exactly_one_check,
  DROP CONSTRAINT IF EXISTS reports_rejection_reason_code_check,
  DROP CONSTRAINT IF EXISTS reports_rejected_reason_check,
  ADD CONSTRAINT reports_target_exactly_one_check
    CHECK ((target_profile_id IS NOT NULL) <> (target_event_id IS NOT NULL)),
  ADD CONSTRAINT reports_rejection_reason_code_check
    CHECK (rejection_reason_code IS NULL OR rejection_reason_code IN (
      'insufficient_evidence', 'duplicate', 'out_of_scope',
      'no_policy_violation', 'other'
    )),
  ADD CONSTRAINT reports_rejected_reason_check
    CHECK (
      (status = 'rejected' AND rejection_reason_code IS NOT NULL)
      OR (status <> 'rejected' AND rejection_reason_code IS NULL)
    );

-- Owner deletion was part of the RLS contract but absent from the original
-- migration. A missing DELETE policy means PostgreSQL denies every delete.
DROP POLICY IF EXISTS events_delete_owner ON public.events;
CREATE POLICY events_delete_owner ON public.events
  FOR DELETE TO authenticated
  USING (creator_id = (select auth.uid()));

DROP POLICY IF EXISTS threads_delete_owner ON public.event_threads;
CREATE POLICY threads_delete_owner ON public.event_threads
  FOR DELETE TO authenticated
  USING (profile_id = (select auth.uid()));

-- Reports remain private to their reporter. Moderation status/reason changes
-- and deletion are performed by the controlled moderation backend only.
DROP POLICY IF EXISTS reports_read_owner ON public.reports;
CREATE POLICY reports_read_owner ON public.reports
  FOR SELECT TO authenticated
  USING (reporter_id = (select auth.uid()));

DROP POLICY IF EXISTS reports_update_owner ON public.reports;
DROP POLICY IF EXISTS reports_delete_owner ON public.reports;
DROP POLICY IF EXISTS reports_admin_update ON public.reports;
DROP POLICY IF EXISTS reports_admin_delete ON public.reports;

-- Admin JWT is not a direct audit-log write capability. Triggers and controlled
-- service-role functions are the only writers.
DROP POLICY IF EXISTS audit_logs_system_insert ON public.audit_logs;
