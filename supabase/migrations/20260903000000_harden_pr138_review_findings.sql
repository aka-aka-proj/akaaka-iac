-- Follow-up hardening for IaC #138 review findings.

-- Profile privacy is enforced at the table boundary.  The viewer-aware
-- resolver is the only browser read path for profile data.
REVOKE SELECT ON TABLE public.profiles FROM authenticated;

CREATE OR REPLACE FUNCTION public.register_event_series_atomic(
  p_series_id UUID,
  p_profile_id UUID,
  p_form_responses JSONB DEFAULT '{}'::jsonb
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
  v_occupied BIGINT;
  v_registration_id UUID;
BEGIN
  -- The Edge Function authenticates p_profile_id.  This RPC is not a browser
  -- API: it is executable only by the service role used by that function.
  PERFORM 1
  FROM public.event_series
  WHERE id = p_series_id AND lifecycle_status = 'published'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'series is not available for registration' USING ERRCODE = 'P0001';
  END IF;

  -- Lock every member event in a stable order before counting capacity.
  FOR v_event IN
    SELECT e.id, e.max_capacity
    FROM public.events AS e
    JOIN public.event_series_membership AS esm ON esm.event_id = e.id
    WHERE esm.series_id = p_series_id
    ORDER BY e.id
    FOR UPDATE OF e
  LOOP
    SELECT COUNT(*) INTO v_occupied
    FROM public.event_registrations AS er
    WHERE er.event_id = v_event.id
      AND er.status IN ('approved', 'pending', 'waitlisted', 'cancellation_pending', 'cancellation_rejected');

    IF v_event.max_capacity IS NOT NULL AND v_occupied >= v_event.max_capacity THEN
      RAISE EXCEPTION 'event capacity exhausted' USING ERRCODE = 'P0001';
    END IF;
    v_event_count := v_event_count + 1;
  END LOOP;

  IF v_event_count = 0 THEN
    RAISE EXCEPTION 'series has no member events' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.event_series_registrations (series_id, profile_id, status, whole_series_registration)
  VALUES (p_series_id, p_profile_id, 'approved', TRUE)
  RETURNING id INTO v_series_registration;

  FOR v_event IN
    SELECT e.id, e.registration_form_config
    FROM public.events AS e
    JOIN public.event_series_membership AS esm ON esm.event_id = e.id
    WHERE esm.series_id = p_series_id
    ORDER BY e.id
  LOOP
    INSERT INTO public.event_registrations (event_id, profile_id, status)
    VALUES (v_event.id, p_profile_id, 'approved')
    RETURNING id INTO v_registration_id;

    IF p_form_responses <> '{}'::jsonb AND v_event.registration_form_config IS NOT NULL THEN
      INSERT INTO public.event_registration_responses (registration_id, responses)
      VALUES (v_registration_id, p_form_responses);
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_series_registration, v_event_count;
END;
$$;

REVOKE ALL ON FUNCTION public.register_event_series_atomic(UUID, UUID, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_event_series_atomic(UUID, UUID, JSONB) TO service_role;
