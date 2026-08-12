-- Unify all social relationship authorization on bidirectional user_follows.
-- A mutual follow is the presence of both directed rows. The legacy
-- connections table and accepted/pending state machine are retired.

BEGIN;

-- The initial migration used a different policy name, so remove both legacy
-- all-users policies before recreating the intended visibility boundary.
DROP POLICY IF EXISTS "Enable read access for all users" ON public.events;
DROP POLICY IF EXISTS events_read_all ON public.events;
DROP POLICY IF EXISTS events_read_visibility ON public.events;

CREATE POLICY events_read_visibility ON public.events
FOR SELECT TO authenticated
USING (
  creator_id = (SELECT auth.uid())
  OR (
    lifecycle_status <> 'draft'
    AND publication_status = 'published'
    AND (
      (visibility_settings ->> 'type') IS NULL
      OR (visibility_settings ->> 'type') = 'public'
      OR (
        (visibility_settings ->> 'type') = 'connections_only'
        AND EXISTS (
          SELECT 1
          FROM public.user_follows f1
          JOIN public.user_follows f2
            ON f2.follower_id = f1.followed_id
           AND f2.followed_id = f1.follower_id
          WHERE f1.follower_id = (SELECT auth.uid())
            AND f1.followed_id = public.events.creator_id
        )
      )
    )
  )
);

-- Event publication notifications use the same visibility contract as event
-- SELECT. Keep the trigger server-side and preserve block filtering.
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
  ON CONFLICT (recipient_profile_id, notification_type, event_id) DO NOTHING;

  RETURN NEW;
END;
$$;

-- No product data currently depends on this legacy table. Fail closed if an
-- unexpected future dependency exists instead of silently cascading it.
DROP TABLE IF EXISTS public.connections;

COMMIT;
