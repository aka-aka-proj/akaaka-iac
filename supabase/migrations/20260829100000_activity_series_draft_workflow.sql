-- Activity series draft-first workflow.
-- A series is created empty as a draft, draft events are added to it, and the
-- owner publishes the whole graph atomically through publish_event_series.

DROP POLICY IF EXISTS event_series_owner_insert ON public.event_series;
CREATE POLICY event_series_owner_insert
  ON public.event_series
  FOR INSERT TO authenticated
  WITH CHECK (creator_id = auth.uid() AND lifecycle_status = 'draft');

DROP POLICY IF EXISTS event_series_owner_update ON public.event_series;
CREATE POLICY event_series_owner_update
  ON public.event_series
  FOR UPDATE TO authenticated
  USING (creator_id = auth.uid())
  WITH CHECK (creator_id = auth.uid() AND lifecycle_status IN ('draft', 'published', 'archived', 'cancelled'));

CREATE OR REPLACE FUNCTION public.prevent_direct_activity_series_publish()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.lifecycle_status IS DISTINCT FROM NEW.lifecycle_status
    AND COALESCE(current_setting('app.activity_series_publish_rpc', true), '') <> 'on'
  THEN
    RAISE EXCEPTION 'activity series lifecycle must be changed through publish_event_series';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_direct_activity_series_publish ON public.event_series;
CREATE TRIGGER trg_prevent_direct_activity_series_publish
  BEFORE UPDATE OF lifecycle_status ON public.event_series
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_direct_activity_series_publish();

DROP POLICY IF EXISTS event_series_membership_insert ON public.event_series_membership;
CREATE POLICY event_series_membership_insert
  ON public.event_series_membership
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.event_series es
      JOIN public.events e ON e.id = event_id
      WHERE es.id = series_id
        AND es.creator_id = auth.uid()
        AND es.lifecycle_status = 'draft'
        AND e.creator_id = auth.uid()
        AND e.lifecycle_status = 'draft'
    )
  );

DROP POLICY IF EXISTS event_series_membership_update ON public.event_series_membership;
CREATE POLICY event_series_membership_update
  ON public.event_series_membership
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.event_series es
      WHERE es.id = series_id AND es.creator_id = auth.uid() AND es.lifecycle_status = 'draft'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.event_series es
      JOIN public.events e ON e.id = event_id
      WHERE es.id = series_id
        AND es.creator_id = auth.uid()
        AND es.lifecycle_status = 'draft'
        AND e.creator_id = auth.uid()
        AND e.lifecycle_status = 'draft'
    )
  );

CREATE OR REPLACE FUNCTION public.publish_event_series(p_series_id UUID)
RETURNS public.event_series
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  series_row public.event_series;
  member_count INTEGER;
  invalid_count INTEGER;
  member_event_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  SELECT * INTO series_row
  FROM public.event_series
  WHERE id = p_series_id
    AND creator_id = auth.uid()
  FOR UPDATE;

  IF series_row.id IS NULL THEN
    RAISE EXCEPTION 'series not found or not owned by caller';
  END IF;
  IF series_row.lifecycle_status <> 'draft' THEN
    RAISE EXCEPTION 'only draft series can be published';
  END IF;

  PERFORM 1
  FROM public.event_series_membership
  WHERE series_id = p_series_id
  ORDER BY position
  FOR UPDATE;

  SELECT COUNT(*) INTO member_count
  FROM public.event_series_membership
  WHERE series_id = p_series_id;
  IF member_count < 2 THEN
    RAISE EXCEPTION 'an activity series requires at least two draft sessions';
  END IF;

  SELECT COUNT(*) INTO invalid_count
  FROM public.event_series_membership m
  JOIN public.events e ON e.id = m.event_id
  WHERE m.series_id = p_series_id
    AND (e.creator_id IS DISTINCT FROM auth.uid() OR e.lifecycle_status <> 'draft');
  IF invalid_count > 0 THEN
    RAISE EXCEPTION 'all activity series sessions must remain draft events owned by caller';
  END IF;

  -- set_event_publication uses the same transaction and publication guard. Any
  -- later failure rolls back all event and series transitions together.
  FOR member_event_id IN
    SELECT event_id
    FROM public.event_series_membership
    WHERE series_id = p_series_id
    ORDER BY position
  LOOP
    PERFORM public.set_event_publication(member_event_id, 'published', NULL, NULL);
  END LOOP;

  PERFORM set_config('app.activity_series_publish_rpc', 'on', true);
  UPDATE public.event_series
  SET lifecycle_status = 'published', updated_at = timezone('utc', now())
  WHERE id = p_series_id
  RETURNING * INTO series_row;

  RETURN series_row;
END;
$$;

REVOKE ALL ON FUNCTION public.publish_event_series(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.publish_event_series(UUID) TO authenticated;
