-- Migration 20260818152128 accidentally reverted the visibility check in
-- notify_subscribers_on_event_publication() from user_follows (mutual-follow
-- pattern, set by 20260813000003) back to the legacy connections table, which
-- 20260813000003 had already dropped. This caused error 42P01 whenever a host
-- published an event with connections_only visibility.
--
-- Fix: restore the user_follows mutual-follow JOIN for the connections_only
-- branch, keeping the NOT EXISTS anti-duplicate pattern from 20260818152128.

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
          FROM public.user_follows f1
          JOIN public.user_follows f2
            ON f2.follower_id = f1.followed_id
           AND f2.followed_id = f1.follower_id
          WHERE f1.follower_id = s.profile_id
            AND f1.followed_id = NEW.creator_id
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