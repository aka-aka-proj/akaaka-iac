-- Issue #96 / frontend#73: "edit scheduled announcement, then publish now"
-- used to be two non-atomic RPCs; a failure in the second step permanently
-- lost the schedule and downgraded the row to a draft. This RPC performs the
-- edit and the publish inside one transaction so any failure — validation,
-- the 12-hour frequency limit, event visibility, permissions — rolls back to
-- the caller's original state (status, schedule and content all preserved).

BEGIN;

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

  -- Lock the row first: validation then targets exactly the state we are
  -- about to mutate, and a concurrent publish cannot flip it underneath us.
  SELECT event_id INTO v_event_id
    FROM public.event_announcements
   WHERE id = p_announcement_id
     AND status IN ('draft', 'scheduled')
   FOR UPDATE;

  IF v_event_id IS NULL THEN
    RAISE EXCEPTION 'announcement not found or immutable';
  END IF;

  -- Ownership, native-registration, length and markdown-safety validation.
  -- publish_at is NULL because this call always publishes immediately.
  PERFORM public.validate_event_announcement_input(
    v_event_id, p_title, p_body_markdown, NULL
  );

  PERFORM set_config('app.event_announcement_rpc', 'on', true);
  UPDATE public.event_announcements
     SET title = btrim(p_title),
         body_markdown = p_body_markdown,
         updated_at = timezone('utc', now())
   WHERE id = p_announcement_id;

  -- Same-transaction publish: the frequency limit, event visibility
  -- re-checks and the notification fan-out all run inside here. Any
  -- exception rolls the edit back too, preserving the caller's original
  -- schedule and content.
  PERFORM public.publish_event_announcement_internal(p_announcement_id);

  SELECT * INTO announcement
    FROM public.event_announcements
   WHERE id = p_announcement_id;

  RETURN announcement;
END;
$$;

REVOKE ALL ON FUNCTION public.update_and_publish_announcement(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_and_publish_announcement(UUID, TEXT, TEXT) TO authenticated;

COMMIT;
