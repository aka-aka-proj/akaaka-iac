-- Harden the three release review findings:
-- 1. all native registration paths lock the event before counting capacity;
-- 2. series registration verifies its membership snapshot inside the transaction;
-- 3. release-state evidence is handled by the workflow using exact merge SHAs.

DROP FUNCTION IF EXISTS public.register_event_series_atomic(UUID, UUID, JSONB);

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
  PERFORM 1
  FROM public.event_series
  WHERE id = p_series_id AND lifecycle_status = 'published'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'series is not available for registration' USING ERRCODE = 'P0001';
  END IF;

  -- Lock the membership rows and event rows in position order. A membership
  -- delete that won the race is reflected in this set and fails the snapshot
  -- comparison below; a delete that starts later waits for this transaction.
  FOR v_event IN
    SELECT esm.event_id, e.id, e.max_capacity
    FROM public.event_series_membership AS esm
    JOIN public.events AS e ON e.id = esm.event_id
    WHERE esm.series_id = p_series_id
    ORDER BY esm.position
    FOR UPDATE OF e, esm
  LOOP
    v_event_ids := array_append(v_event_ids, v_event.event_id);

    SELECT COUNT(*) INTO v_occupied
    FROM public.event_registrations AS er
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
    SELECT e.id, e.registration_form_config
    FROM public.events AS e
    WHERE e.id = ANY(v_event_ids)
    ORDER BY array_position(v_event_ids, e.id)
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

CREATE OR REPLACE FUNCTION public.create_event_registration_atomic(
  p_event_id UUID,
  p_profile_id UUID
)
RETURNS TABLE (
  registration_id UUID,
  event_id UUID,
  status TEXT,
  waitlist_position INTEGER,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_event RECORD;
  v_occupied BIGINT;
  v_status TEXT := 'pending';
  v_waitlist_position INTEGER := NULL;
  v_registration RECORD;
BEGIN
  -- This is the same lock used by the series RPC, so single-event and
  -- whole-series registration cannot both reserve the same last slot.
  SELECT e.id, e.max_capacity
  INTO v_event
  FROM public.events AS e
  WHERE e.id = p_event_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event is not available' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.event_registrations AS er
    WHERE er.event_id = p_event_id
      AND er.profile_id = p_profile_id
      AND er.status <> 'cancelled'
  ) THEN
    RAISE EXCEPTION 'already registered' USING ERRCODE = 'P0001';
  END IF;

  SELECT COUNT(*) INTO v_occupied
  FROM public.event_registrations AS er
  WHERE er.event_id = p_event_id
    AND er.status IN ('approved', 'pending');

  IF v_event.max_capacity IS NOT NULL AND v_occupied >= v_event.max_capacity THEN
    SELECT COALESCE(MAX(er.waitlist_position), 0) + 1
    INTO v_waitlist_position
    FROM public.event_registrations AS er
    WHERE er.event_id = p_event_id
      AND er.status = 'waitlisted';
    v_status := 'waitlisted';
  END IF;

  INSERT INTO public.event_registrations (event_id, profile_id, status, waitlist_position)
  VALUES (p_event_id, p_profile_id, v_status, v_waitlist_position)
  RETURNING id, event_id, status, waitlist_position, created_at INTO v_registration;

  RETURN QUERY SELECT v_registration.id, v_registration.event_id,
    v_registration.status, v_registration.waitlist_position, v_registration.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.register_event_series_atomic(UUID, UUID, JSONB, UUID[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_event_series_atomic(UUID, UUID, JSONB, UUID[]) TO service_role;
REVOKE ALL ON FUNCTION public.create_event_registration_atomic(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_event_registration_atomic(UUID, UUID) TO service_role;
