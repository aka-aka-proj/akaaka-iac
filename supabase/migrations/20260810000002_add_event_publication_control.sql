-- Event publication control is separate from lifecycle_status.
-- The initial events table predates lifecycle_status. Preserve existing events
-- as published, then make newly created events drafts by default.
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS lifecycle_status TEXT NOT NULL DEFAULT 'published';

ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_lifecycle_status_check,
  ADD CONSTRAINT events_lifecycle_status_check
    CHECK (lifecycle_status IN (
      'draft',
      'published',
      'registration_open',
      'registration_closed',
      'completed',
      'archived',
      'cancelled'
    ));

ALTER TABLE public.events
  ALTER COLUMN lifecycle_status SET DEFAULT 'draft';

ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS publication_status TEXT NOT NULL DEFAULT 'closed',
  ADD COLUMN IF NOT EXISTS publish_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS unpublish_at TIMESTAMPTZ;

UPDATE public.events
SET publication_status = CASE
  WHEN lifecycle_status = 'draft' THEN 'closed'
  ELSE 'published'
END
WHERE publication_status = 'closed';

ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_publication_status_check,
  ADD CONSTRAINT events_publication_status_check
    CHECK (publication_status IN ('published', 'closed')),
  DROP CONSTRAINT IF EXISTS events_publication_schedule_order,
  ADD CONSTRAINT events_publication_schedule_order
    CHECK (publish_at IS NULL OR unpublish_at IS NULL OR publish_at < unpublish_at);

CREATE INDEX IF NOT EXISTS idx_events_publication_schedule
  ON public.events (publication_status, publish_at, unpublish_at);

CREATE OR REPLACE FUNCTION public.prevent_direct_event_publication_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF (OLD.publication_status, OLD.publish_at, OLD.unpublish_at)
     IS DISTINCT FROM (NEW.publication_status, NEW.publish_at, NEW.unpublish_at)
    AND COALESCE(current_setting('app.event_publication_rpc', true), '') <> 'on'
  THEN
    RAISE EXCEPTION 'event publication must be changed through set_event_publication';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_direct_event_publication_update ON public.events;
CREATE TRIGGER trg_prevent_direct_event_publication_update
BEFORE UPDATE ON public.events
FOR EACH ROW
EXECUTE FUNCTION public.prevent_direct_event_publication_update();

CREATE OR REPLACE FUNCTION public.set_event_publication(
  p_event_id UUID,
  p_publication_status TEXT,
  p_publish_at TIMESTAMPTZ DEFAULT NULL,
  p_unpublish_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS public.events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  event_row public.events;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  IF p_publication_status NOT IN ('published', 'closed') THEN
    RAISE EXCEPTION 'invalid publication status';
  END IF;

  IF p_publish_at IS NOT NULL AND p_unpublish_at IS NOT NULL
    AND p_publish_at >= p_unpublish_at
  THEN
    RAISE EXCEPTION 'publish_at must be before unpublish_at';
  END IF;

  PERFORM set_config('app.event_publication_rpc', 'on', true);

  UPDATE public.events
  SET publication_status = p_publication_status,
      lifecycle_status = CASE
        WHEN lifecycle_status = 'draft' AND p_publication_status = 'published' THEN 'published'
        ELSE lifecycle_status
      END,
      publish_at = p_publish_at,
      unpublish_at = p_unpublish_at,
      updated_at = timezone('utc', now())
  WHERE id = p_event_id
    AND creator_id = auth.uid()
  RETURNING * INTO event_row;

  IF event_row.id IS NULL THEN
    RAISE EXCEPTION 'event not found or publication transition is not allowed';
  END IF;

  RETURN event_row;
END;
$$;

REVOKE ALL ON FUNCTION public.set_event_publication(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_event_publication(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;

CREATE OR REPLACE FUNCTION public.apply_due_event_publication_schedules()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  changed_count INTEGER;
BEGIN
  PERFORM set_config('app.event_publication_rpc', 'on', true);

  UPDATE public.events
  SET publication_status = CASE
        WHEN unpublish_at IS NOT NULL AND unpublish_at <= timezone('utc', now()) THEN 'closed'
        WHEN publish_at IS NOT NULL AND publish_at <= timezone('utc', now())
          AND lifecycle_status <> 'draft' THEN 'published'
        ELSE publication_status
      END,
      publish_at = CASE
        WHEN publish_at IS NOT NULL AND publish_at <= timezone('utc', now()) THEN NULL
        ELSE publish_at
      END,
      unpublish_at = CASE
        WHEN unpublish_at IS NOT NULL AND unpublish_at <= timezone('utc', now()) THEN NULL
        ELSE unpublish_at
      END,
      updated_at = timezone('utc', now())
  WHERE (publish_at IS NOT NULL AND publish_at <= timezone('utc', now()) AND lifecycle_status <> 'draft')
     OR (unpublish_at IS NOT NULL AND unpublish_at <= timezone('utc', now()));

  GET DIAGNOSTICS changed_count = ROW_COUNT;
  RETURN changed_count;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_due_event_publication_schedules() FROM PUBLIC;

DROP POLICY IF EXISTS events_read_visibility ON public.events;
CREATE POLICY events_read_visibility ON public.events FOR SELECT TO authenticated
USING (
  creator_id = auth.uid()
  OR (
    lifecycle_status <> 'draft'
    AND publication_status = 'published'
    AND (
      (visibility_settings ->> 'type') IS NULL
      OR (visibility_settings ->> 'type') = 'public'
      OR (
        (visibility_settings ->> 'type') = 'connections_only'
        AND EXISTS (
          SELECT 1 FROM public.connections c
          WHERE c.status = 'accepted'
            AND ((c.requester_id = auth.uid() AND c.receiver_id = events.creator_id)
              OR (c.requester_id = events.creator_id AND c.receiver_id = auth.uid()))
        )
      )
    )
  )
);

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
SELECT cron.unschedule('apply-due-event-publication-schedules')
WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'apply-due-event-publication-schedules'
);
SELECT cron.schedule(
  'apply-due-event-publication-schedules',
  '* * * * *',
  $$SELECT public.apply_due_event_publication_schedules();$$
);
