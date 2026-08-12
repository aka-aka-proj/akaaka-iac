-- Allow users to request venue review without granting browser role writes.
-- Notifications contain only generic metadata and the applicant profile id.

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS venue_application_profile_id UUID
    REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_notification_type_check,
  DROP CONSTRAINT IF EXISTS notifications_one_target;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_notification_type_check
    CHECK (notification_type IN ('new_event', 'new_issue', 'new_follow', 'venue_application')),
  ADD CONSTRAINT notifications_one_target
    CHECK (num_nonnulls(event_id, issue_id, actor_profile_id, venue_application_profile_id) = 1);

CREATE UNIQUE INDEX IF NOT EXISTS notifications_venue_application_target_unique
  ON public.notifications (recipient_profile_id, notification_type, venue_application_profile_id)
  WHERE venue_application_profile_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.notify_admins_on_venue_application()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
BEGIN
  IF OLD.role_status IS NOT DISTINCT FROM NEW.role_status
     OR NEW.role_status <> 'venue_pending'
  THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.notifications (
    recipient_profile_id,
    notification_type,
    venue_application_profile_id,
    title
  )
  SELECT p.id, 'venue_application', NEW.id, 'New venue application'
  FROM auth.users u
  JOIN public.profiles p ON p.id = u.id
  WHERE COALESCE(u.raw_app_meta_data ->> 'role', '') = 'admin'
  ON CONFLICT (recipient_profile_id, notification_type, venue_application_profile_id)
    WHERE venue_application_profile_id IS NOT NULL
  DO NOTHING;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_admins_on_venue_application() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_notify_admins_on_venue_application ON public.profiles;
CREATE TRIGGER trg_notify_admins_on_venue_application
AFTER UPDATE OF role_status ON public.profiles
FOR EACH ROW
WHEN (OLD.role_status IS DISTINCT FROM NEW.role_status)
EXECUTE FUNCTION public.notify_admins_on_venue_application();
