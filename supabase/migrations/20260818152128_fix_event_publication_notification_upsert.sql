-- notify_subscribers_on_event_publication() was originally written with
--   ON CONFLICT (recipient_profile_id, notification_type, event_id) DO NOTHING
-- but migration 20260811073932_add_issue_report_notifications.sql dropped the
-- table-level UNIQUE constraint and replaced it with a partial UNIQUE INDEX
-- (notifications_event_target_unique) which PostgreSQL's INSERT ... ON CONFLICT
-- cannot use. This caused error 42P10 whenever a host published an event.
--
-- Fix: replace ON CONFLICT with a NOT EXISTS anti-duplicate check, consistent
-- with the pattern used by notify_admins_on_issue_created() in the same migration.

CREATE OR REPLACE FUNCTION public.notify_subscribers_on_event_publication()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF OLD.publication_status = 'published'
     OR NEW.publication_status <> 'published'
     OR (NEW.visibility_settings ->> 'type') = 'private'
  THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.notifications (
    recipient_profile_id,
    notification_type,
    event_id,
    title
  )
  SELECT DISTINCT s.profile_id, 'new_event', NEW.id, NEW.title
  FROM public.event_notification_subscriptions s
  WHERE s.profile_id <> NEW.creator_id
    AND (
      s.creator_profile_id = NEW.creator_id
      OR s.event_type = NEW.event_type
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.blocks b
      WHERE (b.blocker_id = s.profile_id AND b.blocked_id = NEW.creator_id)
         OR (b.blocker_id = NEW.creator_id AND b.blocked_id = s.profile_id)
    )
    AND (
      COALESCE(NEW.visibility_settings ->> 'type', 'public') = 'public'
      OR (
        NEW.visibility_settings ->> 'type' = 'connections_only'
        AND EXISTS (
          SELECT 1
          FROM public.connections c
          WHERE c.status = 'accepted'
            AND (
              (c.requester_id = s.profile_id AND c.receiver_id = NEW.creator_id)
              OR (c.requester_id = NEW.creator_id AND c.receiver_id = s.profile_id)
            )
        )
      )
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.notifications n
      WHERE n.recipient_profile_id = s.profile_id
        AND n.notification_type = 'new_event'
        AND n.event_id = NEW.id
    );

  RETURN NEW;
END;
$$;