-- Atomic "apply edit + publish now" for event announcements (frontend#73):
-- editing a draft/scheduled announcement and immediately publishing it used to
-- be two RPC calls; a failure of the second one permanently lost the original
-- schedule and downgraded the row to a draft. This controlled RPC performs
-- both steps inside ONE transaction — any failure (12h frequency limit,
-- lifecycle/publication preconditions, validation) rolls the edit back with
-- it, so the original schedule and content survive untouched.
-- Contract: akaaka-docs docs/spec/features/events/007-event-announcements-spec.md
-- §update_and_publish_announcement.
CREATE OR REPLACE FUNCTION public.update_and_publish_announcement(
  p_announcement_id UUID,
  p_title TEXT,
  p_body_markdown TEXT
)
RETURNS public.event_announcements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_event_id UUID;
  announcement public.event_announcements;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication required'; END IF;

  SELECT event_id INTO v_event_id
    FROM public.event_announcements
   WHERE id = p_announcement_id;

  -- Same input rules as update_event_announcement (native event, title/body
  -- length, markdown policy). Runs before any mutation so an invalid payload
  -- cannot leave a half-applied state behind.
  PERFORM public.validate_event_announcement_input(v_event_id, p_title, p_body_markdown, NULL);

  PERFORM set_config('app.event_announcement_rpc', 'on', true);

  UPDATE public.event_announcements a
     SET title = btrim(p_title),
         body_markdown = p_body_markdown,
         updated_at = timezone('utc', now())
   WHERE a.id = p_announcement_id
     AND a.status IN ('draft', 'scheduled')
     AND EXISTS (
       SELECT 1 FROM public.events e
        WHERE e.id = a.event_id AND e.creator_id = auth.uid()
     );
  IF NOT FOUND THEN
    RAISE EXCEPTION 'announcement not found or immutable';
  END IF;

  -- Shared controlled publish path: locks the announcement row, re-checks
  -- native/published/lifecycle preconditions, enforces the 12-hour frequency
  -- rule and fans out notifications exactly once. Any exception here aborts
  -- the whole transaction, rolling back the edit above atomically.
  PERFORM public.publish_event_announcement_internal(p_announcement_id);

  SELECT * INTO announcement
    FROM public.event_announcements
   WHERE id = p_announcement_id;
  RETURN announcement;
END;
$$;

REVOKE ALL ON FUNCTION public.update_and_publish_announcement(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_and_publish_announcement(UUID, TEXT, TEXT) TO authenticated;
