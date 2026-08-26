-- Migration: 20260826020000 Add event_series_registration notification type
-- Description: Extend notifications CHECK constraint for event_series_registration type
--              and add AFTER INSERT trigger on event_series_registrations

-- ============================================================
-- Step 1: Update notifications CHECK constraint
-- ============================================================
ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_notification_type_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_notification_type_check
    CHECK (notification_type IN (
      'new_event', 'new_issue', 'new_follow', 'venue_application',
      'event_invitation', 'event_announcement', 'event_series_registration'
    ));

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
    event_id,
    actor_profile_id,
    title
  )
  VALUES (
    (SELECT es2.creator_id FROM public.event_series es2 WHERE es2.id = NEW.series_id),
    'event_series_registration',
    NULL,
    NEW.profile_id,
    registrant_name || ' registered for the series "' || series_title || '"'
  );

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
