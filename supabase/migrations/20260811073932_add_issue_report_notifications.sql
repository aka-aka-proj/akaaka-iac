-- Extend the existing in-app notification contract for generic admin issue alerts.
-- Issue content remains private; notifications carry only a resource id and generic title.

ALTER TABLE public.notifications
  ALTER COLUMN event_id DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS issue_id UUID REFERENCES public.issues(id) ON DELETE CASCADE;

ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_notification_type_check,
  DROP CONSTRAINT IF EXISTS notifications_one_target,
  DROP CONSTRAINT IF EXISTS notifications_recipient_profile_id_notification_type_event_id_key,
  DROP CONSTRAINT IF EXISTS notifications_recipient_profile_id_notification_type_event__key;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_notification_type_check
    CHECK (notification_type IN ('new_event', 'new_issue')),
  ADD CONSTRAINT notifications_one_target
    CHECK ((event_id IS NOT NULL) <> (issue_id IS NOT NULL));

CREATE UNIQUE INDEX IF NOT EXISTS notifications_event_target_unique
  ON public.notifications (recipient_profile_id, notification_type, event_id)
  WHERE event_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS notifications_issue_target_unique
  ON public.notifications (recipient_profile_id, notification_type, issue_id)
  WHERE issue_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.notify_admins_on_issue_created()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
BEGIN
  INSERT INTO public.notifications (
    recipient_profile_id,
    notification_type,
    issue_id,
    title
  )
  SELECT p.id, 'new_issue', NEW.id, 'New issue report'
  FROM auth.users u
  JOIN public.profiles p ON p.id = u.id
  WHERE COALESCE(u.raw_app_meta_data ->> 'role', '') = 'admin'
    AND NOT EXISTS (
      SELECT 1
      FROM public.notifications n
      WHERE n.recipient_profile_id = p.id
        AND n.notification_type = 'new_issue'
        AND n.issue_id = NEW.id
    );

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_admins_on_issue_created() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_notify_admins_on_issue_created ON public.issues;
CREATE TRIGGER trg_notify_admins_on_issue_created
AFTER INSERT ON public.issues
FOR EACH ROW
EXECUTE FUNCTION public.notify_admins_on_issue_created();
