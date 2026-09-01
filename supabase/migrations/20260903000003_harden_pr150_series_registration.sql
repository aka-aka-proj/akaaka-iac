-- Create the series registration RPC as one remote migration statement.
CREATE OR REPLACE FUNCTION public.register_event_series_atomic(
  p_series_id UUID,
  p_profile_id UUID,
  p_form_responses JSONB DEFAULT '{}'::jsonb,
  p_expected_event_ids UUID[] DEFAULT NULL
)
RETURNS TABLE (registration_id UUID, event_registration_count INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_series_registration UUID;
  v_event RECORD;
  v_event_count INTEGER := 0;
  v_event_ids UUID[] := ARRAY[]::UUID[];
  v_occupied BIGINT;
  v_registration_id UUID;
BEGIN
  PERFORM 1 FROM public.event_series
  WHERE id = p_series_id AND lifecycle_status = 'published'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'series is not available for registration' USING ERRCODE = 'P0001';
  END IF;

  FOR v_event IN
    SELECT esm.event_id, e.id, e.max_capacity
    FROM public.event_series_membership AS esm
    JOIN public.events AS e ON e.id = esm.event_id
    WHERE esm.series_id = p_series_id
    ORDER BY esm.position
    FOR UPDATE OF e, esm
  LOOP
    v_event_ids := array_append(v_event_ids, v_event.event_id);
    SELECT COUNT(*) INTO v_occupied FROM public.event_registrations AS er
    WHERE er.event_id = v_event.event_id
      AND er.status IN ('approved', 'pending', 'waitlisted', 'cancellation_pending', 'cancellation_rejected');
    IF v_event.max_capacity IS NOT NULL AND v_occupied >= v_event.max_capacity THEN
      RAISE EXCEPTION 'event capacity exhausted' USING ERRCODE = 'P0001';
    END IF;
    v_event_count := v_event_count + 1;
  END LOOP;

  IF v_event_count = 0 THEN
    RAISE EXCEPTION 'series has no member events' USING ERRCODE = 'P0001';
  END IF;
  IF p_expected_event_ids IS NULL OR v_event_ids IS DISTINCT FROM p_expected_event_ids THEN
    RAISE EXCEPTION 'series membership changed; please retry' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.event_series_registrations (series_id, profile_id, status, whole_series_registration)
  VALUES (p_series_id, p_profile_id, 'approved', TRUE)
  RETURNING id INTO v_series_registration;

  FOR v_event IN
    SELECT e.id, e.registration_form_config FROM public.events AS e
    WHERE e.id = ANY(v_event_ids) ORDER BY array_position(v_event_ids, e.id)
  LOOP
    INSERT INTO public.event_registrations (event_id, profile_id, status)
    VALUES (v_event.id, p_profile_id, 'approved') RETURNING id INTO v_registration_id;
    IF p_form_responses <> '{}'::jsonb AND v_event.registration_form_config IS NOT NULL THEN
      INSERT INTO public.event_registration_responses (registration_id, responses)
      VALUES (v_registration_id, p_form_responses);
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_series_registration, v_event_count;
END;
$$;
