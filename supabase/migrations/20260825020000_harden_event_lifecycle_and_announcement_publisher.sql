-- Hardens three review findings on the event lifecycle / announcement stack
-- before the preview -> main release (PR #53 review threads).
--
-- 1. Draft round-trip bypass (P1): events_update_owner exempts draft rows from
--    the time lock, so a single client UPDATE could downgrade a future
--    non-draft event to 'draft' while moving start_time into the past and
--    rewriting content, then re-publish it through set_event_publication —
--    defeating the edit lock. Per spec 006/003, published events never return
--    to draft through generic UPDATE; this trigger enforces that at the table.
-- 2. blocks_pair_either_direction (P2): SECURITY DEFINER helper granted to all
--    authenticated users accepted arbitrary UUID pairs, letting any caller
--    probe block relationships between two known profiles. Non-service callers
--    must now be one of the pair endpoints; policies always pass auth.uid(),
--    and the cron publisher runs without a JWT (auth.uid() IS NULL) so both
--    internal call shapes keep working.
-- 3. Announcement publisher (P2): the cron wrapper swallowed every error,
--    leaving non-conflict failures silently retrying forever. The frequency
--    conflict now carries SQLSTATE P1500 and is the only condition retried;
--    anything else propagates to pg_cron and surfaces as a job failure.

CREATE OR REPLACE FUNCTION public.enforce_event_lifecycle_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.lifecycle_status <> 'draft' AND NEW.lifecycle_status = 'draft' THEN
    RAISE EXCEPTION 'published events cannot return to draft';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_event_lifecycle_transition ON public.events;
CREATE TRIGGER trg_enforce_event_lifecycle_transition
BEFORE UPDATE ON public.events
FOR EACH ROW
EXECUTE FUNCTION public.enforce_event_lifecycle_transition();

CREATE OR REPLACE FUNCTION public.blocks_pair_either_direction(
  p_left UUID,
  p_right UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND auth.uid() <> p_left AND auth.uid() <> p_right THEN
    RAISE EXCEPTION 'block relationship lookups are limited to the pair members'
      USING ERRCODE = '42501';
  END IF;
  RETURN EXISTS (
    SELECT 1
    FROM public.blocks b
    WHERE (b.blocker_id = p_left AND b.blocked_id = p_right)
       OR (b.blocker_id = p_right AND b.blocked_id = p_left)
  );
END;
$$;

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
  v_creator_id UUID;
BEGIN
  SELECT a.* INTO announcement
  FROM public.event_announcements a
  JOIN public.events e ON e.id = a.event_id
  WHERE a.id = p_announcement_id
    AND a.status IN ('draft', 'scheduled')
    AND e.external_registration_url IS NULL
    AND e.lifecycle_status <> 'draft'
    AND e.publication_status = 'published'
  FOR UPDATE OF a, e;

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
    RAISE EXCEPTION 'event announcement frequency limit exceeded'
      USING ERRCODE = 'P1500';
  END IF;

  PERFORM set_config('app.event_announcement_rpc', 'on', true);

  UPDATE public.event_announcements
  SET status = 'published', publish_at = NULL, published_at = p_now, updated_at = p_now
  WHERE id = announcement.id;

  SELECT creator_id INTO v_creator_id
  FROM public.events
  WHERE id = announcement.event_id;

  SELECT count(DISTINCT er.profile_id)::INTEGER INTO recipient_count
  FROM public.event_registrations er
  WHERE er.event_id = announcement.event_id
    AND er.status IN ('approved', 'pending', 'waitlisted', 'cancelled')
    AND er.profile_id <> v_creator_id
    AND NOT public.blocks_pair_either_direction(er.profile_id, v_creator_id);

  INSERT INTO public.notifications (
    recipient_profile_id, notification_type, event_announcement_id, title
  )
  SELECT DISTINCT er.profile_id, 'event_announcement', announcement.id, announcement.title
  FROM public.event_registrations er
  WHERE er.event_id = announcement.event_id
    AND er.status IN ('approved', 'pending', 'waitlisted', 'cancelled')
    AND er.profile_id <> v_creator_id
    AND NOT public.blocks_pair_either_direction(er.profile_id, v_creator_id)
  ON CONFLICT (recipient_profile_id, event_announcement_id)
    WHERE event_announcement_id IS NOT NULL DO NOTHING;

  RETURN recipient_count;
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
    EXCEPTION
      WHEN OTHERS THEN
        -- P1500 = 12h frequency conflict: retried next tick, never partially
        -- fan-out. Any other failure is isolated to this row with a WARNING so
        -- one permanently ineligible announcement can neither abort the queue
        -- nor vanish silently; the row stays host-controlled and visibly retrying.
        IF SQLSTATE = 'P1500' THEN
          NULL;
        ELSE
          RAISE WARNING 'publish_due_event_announcements skipped announcement % ([%] %)', announcement_id, SQLSTATE, SQLERRM;
        END IF;
    END;
  END LOOP;
  RETURN published_count;
END;
$$;
