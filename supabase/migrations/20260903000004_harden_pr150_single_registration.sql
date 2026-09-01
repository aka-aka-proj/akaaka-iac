-- Create the single-event registration RPC as one remote migration statement.
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
  SELECT e.id, e.max_capacity INTO v_event FROM public.events AS e
  WHERE e.id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event is not available' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.event_registrations AS er
    WHERE er.event_id = p_event_id AND er.profile_id = p_profile_id AND er.status <> 'cancelled'
  ) THEN
    RAISE EXCEPTION 'already registered' USING ERRCODE = 'P0001';
  END IF;
  SELECT COUNT(*) INTO v_occupied FROM public.event_registrations AS er
  WHERE er.event_id = p_event_id AND er.status IN ('approved', 'pending');
  IF v_event.max_capacity IS NOT NULL AND v_occupied >= v_event.max_capacity THEN
    SELECT COALESCE(MAX(er.waitlist_position), 0) + 1 INTO v_waitlist_position
    FROM public.event_registrations AS er
    WHERE er.event_id = p_event_id AND er.status = 'waitlisted';
    v_status := 'waitlisted';
  END IF;
  INSERT INTO public.event_registrations AS er (event_id, profile_id, status, waitlist_position)
  VALUES (p_event_id, p_profile_id, v_status, v_waitlist_position)
  RETURNING er.id, er.event_id, er.status, er.waitlist_position, er.created_at INTO v_registration;
  RETURN QUERY SELECT v_registration.id, v_registration.event_id, v_registration.status,
    v_registration.waitlist_position, v_registration.created_at;
END;
$$;
