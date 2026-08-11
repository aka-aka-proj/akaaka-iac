-- Notify the followed user when a new follow relationship is created.
-- The notification stores only the actor profile id; profile visibility still
-- applies when the client resolves the actor for display.

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS actor_profile_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_notification_type_check,
  DROP CONSTRAINT IF EXISTS notifications_one_target;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_notification_type_check
    CHECK (notification_type IN ('new_event', 'new_issue', 'new_follow')),
  ADD CONSTRAINT notifications_one_target
    CHECK (num_nonnulls(event_id, issue_id, actor_profile_id) = 1);

CREATE UNIQUE INDEX IF NOT EXISTS notifications_follow_target_unique
  ON public.notifications (recipient_profile_id, notification_type, actor_profile_id)
  WHERE actor_profile_id IS NOT NULL;

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
  ON CONFLICT (recipient_profile_id, notification_type, actor_profile_id) DO NOTHING;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_followed_profile() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_notify_followed_profile ON public.user_follows;
CREATE TRIGGER trg_notify_followed_profile
AFTER INSERT ON public.user_follows
FOR EACH ROW
EXECUTE FUNCTION public.notify_followed_profile();
