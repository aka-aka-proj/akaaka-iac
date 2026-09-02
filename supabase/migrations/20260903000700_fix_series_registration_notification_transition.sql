-- Fix series registration notifications for approval transitions.
-- The original migration handled only INSERT rows that were already approved.

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
  IF NEW.status IS DISTINCT FROM 'approved'
     OR (TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'approved') THEN
    RETURN NEW;
  END IF;

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
  SELECT
    es.creator_id,
    'event_series_registration',
    NEW.series_id,
    NEW.profile_id,
    registrant_name || ' registered for the series "' || series_title || '"'
  FROM public.event_series es
  WHERE es.id = NEW.series_id
    AND es.creator_id IS DISTINCT FROM NEW.profile_id
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
  AFTER INSERT OR UPDATE OF status ON public.event_series_registrations
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_series_registration();
