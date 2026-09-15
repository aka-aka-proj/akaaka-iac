-- Add region targets to event notification subscriptions (docs issue #169).
ALTER TABLE public.event_notification_subscriptions
  ADD COLUMN IF NOT EXISTS location_region TEXT;

ALTER TABLE public.event_notification_subscriptions
  DROP CONSTRAINT IF EXISTS event_notification_subscriptions_exactly_one_target;
ALTER TABLE public.event_notification_subscriptions
  DROP CONSTRAINT IF EXISTS event_notification_subscriptions_target_check;
ALTER TABLE public.event_notification_subscriptions
  ADD CONSTRAINT event_notification_subscriptions_exactly_one_target
    CHECK (num_nonnulls(event_type, creator_profile_id, location_region) = 1);

ALTER TABLE public.event_notification_subscriptions
  DROP CONSTRAINT IF EXISTS event_notification_subscriptions_location_region_check;
ALTER TABLE public.event_notification_subscriptions
  ADD CONSTRAINT event_notification_subscriptions_location_region_check
    CHECK (
      location_region IS NULL
      OR location_region IN ('North', 'Central', 'South', 'East', 'Islands', 'Online')
    );

CREATE UNIQUE INDEX IF NOT EXISTS event_notification_subscriptions_profile_region_uidx
  ON public.event_notification_subscriptions (profile_id, location_region)
  WHERE location_region IS NOT NULL;

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
      OR s.location_region = NEW.location_region
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
