-- Migration: 20260826020000 Add event_series_registration notification type
-- Description: Extend notifications CHECK constraint for event_series_registration type
--              and add AFTER INSERT trigger on event_series_registrations

-- ============================================================
-- Step 1: Update notifications CHECK constraint
-- ============================================================
ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS event_series_id UUID
    REFERENCES public.event_series(id) ON DELETE CASCADE,
  DROP CONSTRAINT IF EXISTS notifications_notification_type_check,
  DROP CONSTRAINT IF EXISTS notifications_one_target;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_notification_type_check
    CHECK (notification_type IN (
      'new_event', 'new_issue', 'new_follow', 'venue_application',
      'event_invitation', 'event_announcement', 'event_series_registration'
    )),
  ADD CONSTRAINT notifications_one_target
    CHECK (
      num_nonnulls(event_id, event_announcement_id, event_series_id, issue_id, actor_profile_id, venue_application_profile_id) = 1
      OR (
        notification_type = 'event_invitation'
        AND event_id IS NOT NULL
        AND actor_profile_id IS NOT NULL
        AND event_announcement_id IS NULL
        AND event_series_id IS NULL
        AND issue_id IS NULL
        AND venue_application_profile_id IS NULL
      )
      OR (
        notification_type = 'event_series_registration'
        AND event_series_id IS NOT NULL
        AND actor_profile_id IS NOT NULL
        AND event_id IS NULL
        AND event_announcement_id IS NULL
        AND issue_id IS NULL
        AND venue_application_profile_id IS NULL
      )
    );

DROP INDEX IF EXISTS public.notifications_follow_target_unique;
CREATE UNIQUE INDEX IF NOT EXISTS notifications_follow_target_unique
  ON public.notifications (recipient_profile_id, notification_type, actor_profile_id)
  WHERE notification_type = 'new_follow'
    AND actor_profile_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS notifications_event_series_registration_target_unique
  ON public.notifications (recipient_profile_id, notification_type, event_series_id, actor_profile_id)
  WHERE notification_type = 'event_series_registration'
    AND event_series_id IS NOT NULL
    AND actor_profile_id IS NOT NULL;

-- ============================================================
-- Step 2: Create trigger function for series registration notification
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_series_registration()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  series_title TEXT;
  registrant_name TEXT;
BEGIN
  SELECT es.title INTO series_title
  FROM public.event_series es
  WHERE es.id = NEW.series_id;

  SELECT COALESCE(p.display_name, 'A member') INTO registrant_name
  FROM public.profiles p
  WHERE p.id = NEW.profile_id;

  INSERT INTO public.notifications (
    recipient_profile_id,
    notification_type,
    event_series_id,
    actor_profile_id,
    title
  )
  VALUES (
    (SELECT es2.creator_id FROM public.event_series es2 WHERE es2.id = NEW.series_id),
    'event_series_registration',
    NEW.series_id,
    NEW.profile_id,
    registrant_name || ' registered for the series "' || series_title || '"'
  )
  ON CONFLICT (recipient_profile_id, notification_type, event_series_id, actor_profile_id)
    WHERE notification_type = 'event_series_registration'
      AND event_series_id IS NOT NULL
      AND actor_profile_id IS NOT NULL
  DO NOTHING;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_series_registration() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_notify_series_registration ON public.event_series_registrations;
CREATE TRIGGER trg_notify_series_registration
  AFTER INSERT ON public.event_series_registrations
  FOR EACH ROW
  WHEN (NEW.status = 'approved')
  EXECUTE FUNCTION public.notify_series_registration();
