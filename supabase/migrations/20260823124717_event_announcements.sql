-- Issue #85: native event announcements with draft/scheduled/published lifecycle.
-- Published announcements are immutable. Notification fan-out is server-side and
-- uses the registration snapshot taken at publish time.

CREATE TABLE IF NOT EXISTS public.event_announcements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  body_markdown TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'scheduled', 'published')),
  publish_at TIMESTAMPTZ,
  published_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT event_announcements_title_length
    CHECK (char_length(btrim(title)) BETWEEN 1 AND 50),
  CONSTRAINT event_announcements_body_length
    CHECK (char_length(body_markdown) BETWEEN 1 AND 1000),
  CONSTRAINT event_announcements_markdown_safety
    CHECK (
      body_markdown !~ '<[^>]+>'
      AND body_markdown !~ '!\[[^]]*\]\([^)]*\)'
      AND body_markdown !~ '\[[^]]+\]\([^)]*\)'
      AND body_markdown !~* '(https?://|www\.)'
    ),
  CONSTRAINT event_announcements_status_consistency
    CHECK (
      (status = 'draft' AND publish_at IS NULL AND published_at IS NULL)
      OR (status = 'scheduled' AND publish_at IS NOT NULL AND published_at IS NULL)
      OR (status = 'published' AND publish_at IS NULL AND published_at IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_event_announcements_event_published_at
  ON public.event_announcements (event_id, published_at DESC)
  WHERE status = 'published';

CREATE INDEX IF NOT EXISTS idx_event_announcements_scheduled
  ON public.event_announcements (publish_at)
  WHERE status = 'scheduled';

-- Registered members retain the same event access for native events even when
-- the event is not public. Blocking or an unpublished/closed event removes it.
DROP POLICY IF EXISTS events_read_visibility ON public.events;
CREATE POLICY events_read_visibility ON public.events FOR SELECT TO authenticated
USING (
  creator_id = auth.uid()
  OR (
    lifecycle_status <> 'draft'
    AND publication_status = 'published'
    AND NOT EXISTS (
      SELECT 1
      FROM public.blocks b
      WHERE (b.blocker_id = auth.uid() AND b.blocked_id = events.creator_id)
         OR (b.blocker_id = events.creator_id AND b.blocked_id = auth.uid())
    )
    AND (
      EXISTS (
        SELECT 1
        FROM public.event_registrations er
        WHERE er.event_id = events.id
          AND er.profile_id = auth.uid()
          AND er.status IN ('approved', 'pending', 'waitlisted', 'cancelled')
      )
      OR (visibility_settings ->> 'type') IS NULL
      OR (visibility_settings ->> 'type') = 'public'
      OR (
        visibility_settings ->> 'type' = 'connections_only'
        AND EXISTS (
          SELECT 1
          FROM public.user_follows f1
          JOIN public.user_follows f2
            ON f2.follower_id = f1.followed_id
           AND f2.followed_id = f1.follower_id
          WHERE f1.follower_id = auth.uid()
            AND f1.followed_id = events.creator_id
        )
      )
    )
  )
);

ALTER TABLE public.event_announcements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS event_announcements_select_access ON public.event_announcements;
CREATE POLICY event_announcements_select_access
  ON public.event_announcements FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.events e
      WHERE e.id = event_announcements.event_id
        AND (
          e.creator_id = auth.uid()
          OR (
            event_announcements.status = 'published'
            AND e.lifecycle_status <> 'draft'
            AND e.publication_status = 'published'
            AND NOT EXISTS (
              SELECT 1
              FROM public.blocks b
              WHERE (b.blocker_id = auth.uid() AND b.blocked_id = e.creator_id)
                 OR (b.blocker_id = e.creator_id AND b.blocked_id = auth.uid())
            )
            AND (
              EXISTS (
                SELECT 1
                FROM public.event_registrations er
                WHERE er.event_id = e.id
                  AND er.profile_id = auth.uid()
                  AND er.status IN ('approved', 'pending', 'waitlisted', 'cancelled')
              )
              OR
              COALESCE(e.visibility_settings ->> 'type', 'public') = 'public'
              OR (
                e.visibility_settings ->> 'type' = 'connections_only'
                AND EXISTS (
                  SELECT 1
                  FROM public.user_follows f1
                  JOIN public.user_follows f2
                    ON f2.follower_id = f1.followed_id
                   AND f2.followed_id = f1.follower_id
                  WHERE f1.follower_id = auth.uid()
                    AND f1.followed_id = e.creator_id
                )
              )
            )
          )
        )
    )
  );

-- The browser has no direct INSERT/UPDATE/DELETE grant. Owner RPCs and the
-- scheduler use SECURITY DEFINER and set this transaction-local guard.
REVOKE ALL ON public.event_announcements FROM anon, authenticated;
GRANT SELECT ON public.event_announcements TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.event_announcements TO service_role;

-- Keep the existing provider claim signature stable while resolving the event
-- target for announcement notifications through the announcement row.
CREATE OR REPLACE FUNCTION public.claim_notification_push_deliveries(
  p_limit INTEGER DEFAULT 25,
  p_now TIMESTAMPTZ DEFAULT timezone('utc', now())
)
RETURNS TABLE (
  delivery_id UUID,
  notification_id UUID,
  push_subscription_id UUID,
  idempotency_key TEXT,
  attempts INTEGER,
  notification_type TEXT,
  event_id UUID,
  actor_profile_id UUID,
  venue_application_profile_id UUID,
  endpoint TEXT,
  p256dh TEXT,
  auth TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF p_limit < 1 OR p_limit > 100 THEN RAISE EXCEPTION 'invalid_delivery_limit'; END IF;

  UPDATE public.notification_push_deliveries d
  SET status = 'endpoint_invalid', last_error_code = 'subscription_missing', updated_at = p_now
  WHERE d.status IN ('pending', 'processing')
    AND NOT EXISTS (SELECT 1 FROM public.push_subscriptions ps WHERE ps.id = d.push_subscription_id);

  RETURN QUERY
  WITH candidates AS (
    SELECT d.id
    FROM public.notification_push_deliveries d
    JOIN public.push_subscriptions ps ON ps.id = d.push_subscription_id
    WHERE (d.status = 'pending' AND d.available_at <= p_now)
       OR (d.status = 'processing' AND d.claimed_at < p_now - interval '5 minutes')
    ORDER BY d.available_at, d.created_at, d.id
    LIMIT p_limit
    FOR UPDATE OF d SKIP LOCKED
  ), claimed AS (
    UPDATE public.notification_push_deliveries d
    SET status = 'processing', attempts = d.attempts + 1, claimed_at = p_now, updated_at = p_now
    FROM candidates c
    WHERE d.id = c.id
    RETURNING d.*
  )
  SELECT c.id, c.notification_id, c.push_subscription_id, c.idempotency_key, c.attempts,
         n.notification_type, COALESCE(n.event_id, ea.event_id), n.actor_profile_id,
         n.venue_application_profile_id, ps.endpoint, ps.p256dh, ps.auth
  FROM claimed c
  JOIN public.notifications n ON n.id = c.notification_id
  LEFT JOIN public.event_announcements ea ON ea.id = n.event_announcement_id
  JOIN public.push_subscriptions ps ON ps.id = c.push_subscription_id;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_notification_push_deliveries(INTEGER, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_notification_push_deliveries(INTEGER, TIMESTAMPTZ) TO service_role;

CREATE OR REPLACE FUNCTION public.prevent_direct_event_announcement_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'event announcements cannot be deleted';
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.status = 'published' THEN
    RAISE EXCEPTION 'published event announcements are immutable';
  END IF;

  IF COALESCE(current_setting('app.event_announcement_rpc', true), '') <> 'on'
     AND (TG_OP = 'INSERT' OR TG_OP = 'UPDATE')
  THEN
    RAISE EXCEPTION 'event announcements must use the controlled RPC';
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

REVOKE ALL ON FUNCTION public.prevent_direct_event_announcement_mutation() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_prevent_direct_event_announcement_mutation ON public.event_announcements;
CREATE TRIGGER trg_prevent_direct_event_announcement_mutation
BEFORE INSERT OR UPDATE OR DELETE ON public.event_announcements
FOR EACH ROW
EXECUTE FUNCTION public.prevent_direct_event_announcement_mutation();

CREATE OR REPLACE FUNCTION public.prevent_external_registration_with_announcements()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.external_registration_url IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.event_announcements a WHERE a.event_id = NEW.id)
  THEN
    RAISE EXCEPTION 'events with announcements cannot use external registration';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.prevent_external_registration_with_announcements() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_prevent_external_registration_with_announcements ON public.events;
CREATE TRIGGER trg_prevent_external_registration_with_announcements
BEFORE UPDATE OF external_registration_url ON public.events
FOR EACH ROW
EXECUTE FUNCTION public.prevent_external_registration_with_announcements();

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS event_announcement_id UUID
    REFERENCES public.event_announcements(id) ON DELETE CASCADE;

ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_notification_type_check,
  DROP CONSTRAINT IF EXISTS notifications_one_target;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_notification_type_check
    CHECK (notification_type IN (
      'new_event', 'new_issue', 'new_follow', 'venue_application',
      'event_invitation', 'event_announcement'
    )),
  ADD CONSTRAINT notifications_one_target
    CHECK (
      num_nonnulls(event_id, event_announcement_id, issue_id, actor_profile_id, venue_application_profile_id) = 1
      OR (
        notification_type = 'event_invitation'
        AND event_id IS NOT NULL
        AND actor_profile_id IS NOT NULL
        AND event_announcement_id IS NULL
        AND issue_id IS NULL
        AND venue_application_profile_id IS NULL
      )
    );

CREATE UNIQUE INDEX IF NOT EXISTS notifications_event_announcement_target_unique
  ON public.notifications (recipient_profile_id, event_announcement_id)
  WHERE event_announcement_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.validate_event_announcement_input(
  p_event_id UUID,
  p_title TEXT,
  p_body_markdown TEXT,
  p_publish_at TIMESTAMPTZ
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  event_row public.events;
BEGIN
  SELECT * INTO event_row FROM public.events WHERE id = p_event_id;
  IF event_row.id IS NULL OR event_row.creator_id <> auth.uid() THEN
    RAISE EXCEPTION 'event not found or caller is not the host';
  END IF;
  IF event_row.external_registration_url IS NOT NULL THEN
    RAISE EXCEPTION 'event announcements require native registration';
  END IF;
  IF char_length(btrim(p_title)) NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'announcement title must be 1 to 50 characters';
  END IF;
  IF char_length(p_body_markdown) NOT BETWEEN 1 AND 1000
     OR p_body_markdown ~ '<[^>]+>'
     OR p_body_markdown ~ '!\[[^]]*\]\([^)]*\)'
     OR p_body_markdown ~ '\[[^]]+\]\([^)]*\)'
     OR p_body_markdown ~* '(https?://|www\.)'
  THEN
    RAISE EXCEPTION 'announcement body is invalid';
  END IF;
  IF p_publish_at IS NOT NULL AND p_publish_at <= timezone('utc', now()) THEN
    RAISE EXCEPTION 'scheduled publish time must be in the future';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_event_announcement_input(UUID, TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.publish_event_announcement_internal(
  p_announcement_id UUID,
  p_now TIMESTAMPTZ DEFAULT timezone('utc', now())
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  announcement public.event_announcements;
  recipient_count INTEGER := 0;
BEGIN
  SELECT a.* INTO announcement
  FROM public.event_announcements a
  JOIN public.events e ON e.id = a.event_id
  WHERE a.id = p_announcement_id
    AND a.status IN ('draft', 'scheduled')
    AND e.external_registration_url IS NULL
  FOR UPDATE OF a;

  IF announcement.id IS NULL THEN
    RAISE EXCEPTION 'announcement not found or cannot be published';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.event_announcements a
    WHERE a.event_id = announcement.event_id
      AND a.status = 'published'
      AND a.id <> announcement.id
      AND a.published_at > p_now - interval '12 hours'
  ) THEN
    RAISE EXCEPTION 'event announcement frequency limit exceeded';
  END IF;

  PERFORM set_config('app.event_announcement_rpc', 'on', true);
  UPDATE public.event_announcements
  SET status = 'published', publish_at = NULL, published_at = p_now, updated_at = p_now
  WHERE id = announcement.id;

  SELECT count(DISTINCT er.profile_id)::INTEGER INTO recipient_count
  FROM public.event_registrations er
  WHERE er.event_id = announcement.event_id
    AND er.status IN ('approved', 'pending', 'waitlisted', 'cancelled');

  INSERT INTO public.notifications (
    recipient_profile_id, notification_type, event_announcement_id, title
  )
  SELECT DISTINCT er.profile_id, 'event_announcement', announcement.id, announcement.title
  FROM public.event_registrations er
  WHERE er.event_id = announcement.event_id
    AND er.status IN ('approved', 'pending', 'waitlisted', 'cancelled')
    AND er.profile_id <> (SELECT creator_id FROM public.events WHERE id = announcement.event_id)
  ON CONFLICT (recipient_profile_id, event_announcement_id) DO NOTHING;

  RETURN recipient_count;
END;
$$;

REVOKE ALL ON FUNCTION public.publish_event_announcement_internal(UUID, TIMESTAMPTZ) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.create_event_announcement(
  p_event_id UUID,
  p_title TEXT,
  p_body_markdown TEXT,
  p_publish_at TIMESTAMPTZ DEFAULT NULL,
  p_publish_now BOOLEAN DEFAULT FALSE
)
RETURNS public.event_announcements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  announcement public.event_announcements;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;
  IF p_publish_now AND p_publish_at IS NOT NULL THEN RAISE EXCEPTION 'choose publish now or schedule'; END IF;
  PERFORM public.validate_event_announcement_input(p_event_id, p_title, p_body_markdown, p_publish_at);
  IF (SELECT count(*) FROM public.event_announcements WHERE event_id = p_event_id) >= 5 THEN
    RAISE EXCEPTION 'event announcement limit exceeded';
  END IF;

  PERFORM set_config('app.event_announcement_rpc', 'on', true);
  INSERT INTO public.event_announcements (event_id, title, body_markdown, status, publish_at, published_at)
  VALUES (
    p_event_id, btrim(p_title), p_body_markdown,
    CASE WHEN p_publish_now THEN 'published' WHEN p_publish_at IS NOT NULL THEN 'scheduled' ELSE 'draft' END,
    CASE WHEN p_publish_now THEN NULL ELSE p_publish_at END,
    CASE WHEN p_publish_now THEN timezone('utc', now()) ELSE NULL END
  )
  RETURNING * INTO announcement;

  IF p_publish_now THEN
    -- The insert is already published; enforce the interval before fan-out.
    IF EXISTS (
      SELECT 1 FROM public.event_announcements a
      WHERE a.event_id = p_event_id AND a.status = 'published'
        AND a.id <> announcement.id
        AND a.published_at > announcement.published_at - interval '12 hours'
    ) THEN
      RAISE EXCEPTION 'event announcement frequency limit exceeded';
    END IF;
    INSERT INTO public.notifications (recipient_profile_id, notification_type, event_announcement_id, title)
    SELECT DISTINCT er.profile_id, 'event_announcement', announcement.id, announcement.title
    FROM public.event_registrations er
    WHERE er.event_id = p_event_id
      AND er.status IN ('approved', 'pending', 'waitlisted', 'cancelled')
      AND er.profile_id <> (SELECT creator_id FROM public.events WHERE id = p_event_id)
    ON CONFLICT (recipient_profile_id, event_announcement_id) DO NOTHING;
  END IF;

  RETURN announcement;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_event_announcement(
  p_announcement_id UUID,
  p_title TEXT,
  p_body_markdown TEXT,
  p_status TEXT DEFAULT 'draft',
  p_publish_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS public.event_announcements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  announcement public.event_announcements;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;
  IF p_status NOT IN ('draft', 'scheduled') THEN RAISE EXCEPTION 'invalid editable announcement status'; END IF;
  PERFORM public.validate_event_announcement_input(
    (SELECT event_id FROM public.event_announcements WHERE id = p_announcement_id),
    p_title, p_body_markdown,
    CASE WHEN p_status = 'scheduled' THEN p_publish_at ELSE NULL END
  );
  IF p_status = 'scheduled' AND p_publish_at IS NULL THEN RAISE EXCEPTION 'scheduled announcement needs publish_at'; END IF;

  PERFORM set_config('app.event_announcement_rpc', 'on', true);
  UPDATE public.event_announcements a
  SET title = btrim(p_title), body_markdown = p_body_markdown, status = p_status,
      publish_at = CASE WHEN p_status = 'scheduled' THEN p_publish_at ELSE NULL END,
      updated_at = timezone('utc', now())
  WHERE a.id = p_announcement_id
    AND a.status IN ('draft', 'scheduled')
    AND EXISTS (SELECT 1 FROM public.events e WHERE e.id = a.event_id AND e.creator_id = auth.uid())
  RETURNING a.* INTO announcement;
  IF announcement.id IS NULL THEN RAISE EXCEPTION 'announcement not found or immutable'; END IF;
  RETURN announcement;
END;
$$;

CREATE OR REPLACE FUNCTION public.publish_event_announcement(p_announcement_id UUID)
RETURNS public.event_announcements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  announcement public.event_announcements;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.event_announcements a
    JOIN public.events e ON e.id = a.event_id
    WHERE a.id = p_announcement_id AND e.creator_id = auth.uid()
  ) THEN RAISE EXCEPTION 'announcement not found or caller is not the host'; END IF;
  PERFORM public.publish_event_announcement_internal(p_announcement_id);
  SELECT * INTO announcement FROM public.event_announcements WHERE id = p_announcement_id;
  RETURN announcement;
END;
$$;

CREATE OR REPLACE FUNCTION public.publish_due_event_announcements()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  announcement_id UUID;
  published_count INTEGER := 0;
BEGIN
  FOR announcement_id IN
    SELECT id FROM public.event_announcements
    WHERE status = 'scheduled' AND publish_at <= timezone('utc', now())
    ORDER BY publish_at, id
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      PERFORM public.publish_event_announcement_internal(announcement_id);
      published_count := published_count + 1;
    EXCEPTION WHEN OTHERS THEN
      -- A frequency conflict is retried by the next scheduler tick; no partial
      -- notification fan-out is committed for the failed announcement.
      NULL;
    END;
  END LOOP;
  RETURN published_count;
END;
$$;

REVOKE ALL ON FUNCTION public.create_event_announcement(UUID, TEXT, TEXT, TIMESTAMPTZ, BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_event_announcement(UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.publish_event_announcement(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.publish_due_event_announcements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_event_announcement(UUID, TEXT, TEXT, TIMESTAMPTZ, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_event_announcement(UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.publish_event_announcement(UUID) TO authenticated;

SELECT cron.unschedule('publish-due-event-announcements')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'publish-due-event-announcements');
SELECT cron.schedule(
  'publish-due-event-announcements',
  '* * * * *',
  $$SELECT public.publish_due_event_announcements();$$
);

GRANT SELECT ON public.event_announcements TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.event_announcements TO service_role;
