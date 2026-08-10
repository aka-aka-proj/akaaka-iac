-- Activity notifications: subscriptions by event type or creator.
-- Existing events are intentionally not backfilled; only future publication
-- transitions create notifications.

CREATE TABLE IF NOT EXISTS public.event_notification_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  event_type TEXT,
  creator_profile_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT event_notification_subscriptions_one_target
    CHECK ((event_type IS NOT NULL) <> (creator_profile_id IS NOT NULL)),
  CONSTRAINT event_notification_subscriptions_event_type_check
    CHECK (event_type IS NULL OR event_type IN (
      'Bondage', 'Discipline', 'Dominance / Submission', 'D/S',
      'Sadism / Masochism', 'SM', 'SP', 'Spanking', 'TK', 'Tickling',
      'K9', 'DID', 'CNC', 'DDLG', '4 love', 'ABDL',
      'Dining', 'BBQ', 'Karaoke', 'Movie', 'BoardGame', 'Travel',
      'BookClub', 'Conversation', 'SpeedDating', 'HangOut'
    )),
  CONSTRAINT event_notification_subscriptions_not_self
    CHECK (creator_profile_id IS NULL OR creator_profile_id <> profile_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_event_notification_subscriptions_type
  ON public.event_notification_subscriptions (profile_id, event_type)
  WHERE event_type IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_event_notification_subscriptions_creator
  ON public.event_notification_subscriptions (profile_id, creator_profile_id)
  WHERE creator_profile_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_event_notification_subscriptions_event_type
  ON public.event_notification_subscriptions (event_type, profile_id)
  WHERE event_type IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  notification_type TEXT NOT NULL
    CHECK (notification_type IN ('new_event')),
  event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  read_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (recipient_profile_id, notification_type, event_id)
);

CREATE INDEX IF NOT EXISTS idx_notifications_recipient_created_at
  ON public.notifications (recipient_profile_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_notifications_unread
  ON public.notifications (recipient_profile_id, created_at DESC)
  WHERE read_at IS NULL;

ALTER TABLE public.event_notification_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS event_notification_subscriptions_select_self
  ON public.event_notification_subscriptions;
CREATE POLICY event_notification_subscriptions_select_self
  ON public.event_notification_subscriptions FOR SELECT TO authenticated
  USING (profile_id = auth.uid());

DROP POLICY IF EXISTS event_notification_subscriptions_insert_self
  ON public.event_notification_subscriptions;
CREATE POLICY event_notification_subscriptions_insert_self
  ON public.event_notification_subscriptions FOR INSERT TO authenticated
  WITH CHECK (
    (
      profile_id = auth.uid()
      AND creator_profile_id IS NULL
    ) OR (
      profile_id = auth.uid()
      AND creator_profile_id IS NOT NULL
      AND creator_profile_id <> auth.uid()
      AND EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = creator_profile_id)
    )
  );

DROP POLICY IF EXISTS event_notification_subscriptions_delete_self
  ON public.event_notification_subscriptions;
CREATE POLICY event_notification_subscriptions_delete_self
  ON public.event_notification_subscriptions FOR DELETE TO authenticated
  USING (profile_id = auth.uid());

DROP POLICY IF EXISTS notifications_select_recipient
  ON public.notifications;
CREATE POLICY notifications_select_recipient
  ON public.notifications FOR SELECT TO authenticated
  USING (recipient_profile_id = auth.uid());

DROP POLICY IF EXISTS notifications_update_read_at
  ON public.notifications;
CREATE POLICY notifications_update_read_at
  ON public.notifications FOR UPDATE TO authenticated
  USING (recipient_profile_id = auth.uid())
  WITH CHECK (recipient_profile_id = auth.uid());

-- Browser clients may only update the read marker, never notification content
-- or recipient ownership.
REVOKE UPDATE ON public.notifications FROM authenticated;
GRANT UPDATE (read_at) ON public.notifications TO authenticated;

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
  ON CONFLICT (recipient_profile_id, notification_type, event_id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_subscribers_on_event_publication ON public.events;
CREATE TRIGGER trg_notify_subscribers_on_event_publication
AFTER UPDATE OF publication_status ON public.events
FOR EACH ROW
WHEN (OLD.publication_status IS DISTINCT FROM NEW.publication_status)
EXECUTE FUNCTION public.notify_subscribers_on_event_publication();
