-- Spec 006 (event publication control): 草稿不得預約公開。
--
-- Draft events stay invisible until their owner manually publishes them through
-- set_event_publication, and apply_due_event_publication_schedules() skips
-- drafts by design (`lifecycle_status <> 'draft'`). A publish_at/unpublish_at
-- stored on a draft therefore can never fire. The RPC now refuses to store
-- schedules on drafts instead of silently keeping dead rows, and legacy
-- schedules saved before this rule are cleared by the backfill below.
--
-- Docs: akaaka-docs docs/spec/features/events/006-event-publication-control-spec.md

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

  IF (p_publish_at IS NOT NULL OR p_unpublish_at IS NOT NULL)
    AND EXISTS (
      SELECT 1
      FROM public.events
      WHERE id = p_event_id
        AND creator_id = auth.uid()
        AND lifecycle_status = 'draft'
    )
  THEN
    RAISE EXCEPTION 'draft events cannot have publication schedules';
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

SELECT set_config('app.event_publication_rpc', 'on', true);

UPDATE public.events
SET publish_at = NULL,
    unpublish_at = NULL,
    updated_at = timezone('utc', now())
WHERE lifecycle_status = 'draft'
  AND (publish_at IS NOT NULL OR unpublish_at IS NOT NULL);
