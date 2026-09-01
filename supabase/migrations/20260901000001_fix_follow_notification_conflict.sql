-- Fix follow notification ON CONFLICT inference after the notification
-- uniqueness predicate was narrowed to new_follow notifications.
DROP INDEX IF EXISTS public.notifications_follow_target_unique;

CREATE UNIQUE INDEX notifications_follow_target_unique
  ON public.notifications (recipient_profile_id, notification_type, actor_profile_id)
  WHERE notification_type = 'new_follow'
    AND actor_profile_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.notify_followed_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.blocks b
    WHERE (b.blocker_id = NEW.follower_id AND b.blocked_id = NEW.followed_id)
       OR (b.blocker_id = NEW.followed_id AND b.blocked_id = NEW.follower_id)
  ) THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.notifications (
    recipient_profile_id,
    notification_type,
    actor_profile_id,
    title
  )
  VALUES (NEW.followed_id, 'new_follow', NEW.follower_id, 'New follower')
  ON CONFLICT (recipient_profile_id, notification_type, actor_profile_id)
    WHERE notification_type = 'new_follow'
      AND actor_profile_id IS NOT NULL
  DO NOTHING;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_followed_profile() FROM PUBLIC;
