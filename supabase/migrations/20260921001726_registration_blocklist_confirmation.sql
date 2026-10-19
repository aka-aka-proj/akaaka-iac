-- Consent belongs to a single service-controlled transaction, never a caller GUC.
CREATE TABLE private.registration_blocklist_acknowledgements (
  transaction_id bigint NOT NULL,
  event_id uuid NOT NULL,
  profile_id uuid NOT NULL,
  action text NOT NULL CHECK (action IN ('register', 'review')),
  PRIMARY KEY (transaction_id, event_id, profile_id, action)
);
ALTER TABLE private.registration_blocklist_acknowledgements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.registration_blocklist_acknowledgements FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION private.check_registration_blocklist()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_host uuid;
  v_action text;
  v_conflict boolean;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.event_id IS DISTINCT FROM OLD.event_id OR NEW.profile_id IS DISTINCT FROM OLD.profile_id THEN
      RAISE EXCEPTION 'registration_identity_immutable' USING ERRCODE = 'P0001';
    END IF;
    IF OLD.status IN ('rejected', 'cancelled') AND NEW.status IN ('pending', 'approved', 'waitlisted', 'cancellation_pending', 'cancellation_rejected') THEN
      RAISE EXCEPTION 'invalid_status_transition' USING ERRCODE = 'P0001';
    END IF;
    IF OLD.status = 'waitlisted' AND NEW.status = 'approved' THEN
      RAISE EXCEPTION 'invalid_status_transition' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.status <> 'approved' OR OLD.status <> 'pending' THEN
      RETURN NEW;
    END IF;
    v_action := 'review';
  ELSE
    IF NEW.status NOT IN ('pending', 'approved', 'waitlisted', 'cancellation_pending', 'cancellation_rejected') THEN
      RETURN NEW;
    END IF;
    v_action := 'register';
  END IF;

  SELECT e.creator_id INTO v_host FROM public.events e WHERE e.id = NEW.event_id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM public.blocks b WHERE
    (b.blocker_id = v_host AND b.blocked_id = NEW.profile_id) OR
    (b.blocker_id = NEW.profile_id AND b.blocked_id = v_host)) THEN
    RAISE EXCEPTION 'registration_blocked' USING ERRCODE = 'P0001';
  END IF;

  IF v_action = 'register' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.event_registrations r JOIN public.blocks b ON b.blocked_id = r.profile_id
      WHERE r.event_id = NEW.event_id AND r.profile_id <> NEW.profile_id
        AND r.status IN ('pending', 'approved', 'waitlisted', 'cancellation_pending', 'cancellation_rejected')
        AND b.blocker_id = NEW.profile_id
    ) INTO v_conflict;
  ELSE
    SELECT EXISTS (
      SELECT 1 FROM public.event_registrations r JOIN public.blocks b ON
        (b.blocker_id = NEW.profile_id AND b.blocked_id = r.profile_id) OR
        (b.blocked_id = NEW.profile_id AND b.blocker_id = r.profile_id)
      WHERE r.event_id = NEW.event_id AND r.profile_id <> NEW.profile_id
        AND r.status IN ('approved', 'cancellation_pending', 'cancellation_rejected')
    ) INTO v_conflict;
  END IF;
  IF v_conflict AND NOT EXISTS (
    SELECT 1 FROM private.registration_blocklist_acknowledgements a
    WHERE a.transaction_id = txid_current() AND a.event_id = NEW.event_id
      AND a.profile_id = NEW.profile_id AND a.action = v_action
  ) THEN
    RAISE EXCEPTION 'blocklist_confirmation_required' USING ERRCODE = 'P0001', DETAIL = NEW.event_id::text;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.check_registration_blocklist() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER check_registration_blocklist BEFORE INSERT OR UPDATE OF status, event_id, profile_id
ON public.event_registrations FOR EACH ROW EXECUTE FUNCTION private.check_registration_blocklist();

CREATE FUNCTION public.create_event_registration_checked(
  p_event_id uuid, p_profile_id uuid, p_acknowledge_blocklist_conflict boolean DEFAULT false
)
RETURNS TABLE (registration_id uuid, event_id uuid, status text, waitlist_position integer, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_acknowledge_blocklist_conflict THEN
    INSERT INTO private.registration_blocklist_acknowledgements VALUES (txid_current(),p_event_id,p_profile_id,'register');
  END IF;
  RETURN QUERY SELECT * FROM public.create_event_registration_atomic(p_event_id,p_profile_id);
  DELETE FROM private.registration_blocklist_acknowledgements a
    WHERE a.transaction_id=txid_current() AND a.event_id=p_event_id AND a.profile_id=p_profile_id AND a.action='register';
END;
$$;

CREATE FUNCTION public.register_event_series_checked(
  p_series_id uuid, p_profile_id uuid, p_form_responses jsonb, p_expected_event_ids uuid[],
  p_acknowledge_blocklist_conflict boolean DEFAULT false
)
RETURNS TABLE (registration_id uuid, event_registration_count integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_acknowledge_blocklist_conflict THEN
    INSERT INTO private.registration_blocklist_acknowledgements
      SELECT txid_current(), e, p_profile_id, 'register' FROM unnest(p_expected_event_ids) e;
  END IF;
  RETURN QUERY SELECT * FROM public.register_event_series_atomic(p_series_id,p_profile_id,p_form_responses,p_expected_event_ids);
  DELETE FROM private.registration_blocklist_acknowledgements a
    WHERE a.transaction_id=txid_current() AND a.event_id=ANY(p_expected_event_ids) AND a.profile_id=p_profile_id AND a.action='register';
END;
$$;

CREATE FUNCTION public.review_event_registration_checked(
  p_event_id uuid, p_registration_id uuid, p_host_id uuid, p_action text,
  p_acknowledge_blocklist_conflict boolean DEFAULT false
)
RETURNS TABLE (id uuid, status text, reviewed_by uuid, reviewed_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_event public.events%ROWTYPE;
  v_reg public.event_registrations%ROWTYPE;
  v_status text;
BEGIN
  SELECT * INTO v_event FROM public.events e WHERE e.id=p_event_id FOR UPDATE;
  IF NOT FOUND OR v_event.creator_id IS DISTINCT FROM p_host_id THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE='P0001';
  END IF;
  SELECT * INTO v_reg FROM public.event_registrations r WHERE r.id=p_registration_id AND r.event_id=p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0001'; END IF;
  IF v_reg.status='pending' AND p_action IN ('approve','reject') THEN
    v_status := CASE WHEN p_action='approve' THEN 'approved' ELSE 'rejected' END;
    IF v_status='approved' AND v_event.max_capacity IS NOT NULL AND (
      SELECT count(*) FROM public.event_registrations r WHERE r.event_id=p_event_id
        AND r.status IN ('approved','cancellation_pending','cancellation_rejected')
    ) >= v_event.max_capacity THEN
      RAISE EXCEPTION 'capacity_reached' USING ERRCODE='P0001';
    END IF;
  ELSIF v_reg.status='cancellation_pending' AND p_action IN ('approve','reject') THEN
    v_status := CASE WHEN p_action='approve' THEN 'cancelled' ELSE 'cancellation_rejected' END;
  ELSIF v_reg.status='cancellation_rejected' AND p_action='reopen' THEN
    v_status := 'cancellation_pending';
  ELSE
    RAISE EXCEPTION 'invalid_status_transition' USING ERRCODE='P0001';
  END IF;
  IF p_acknowledge_blocklist_conflict AND v_status='approved' THEN
    INSERT INTO private.registration_blocklist_acknowledgements VALUES (txid_current(),p_event_id,v_reg.profile_id,'review');
  END IF;
  RETURN QUERY UPDATE public.event_registrations r
    SET status=v_status,reviewed_by=p_host_id,reviewed_at=now() WHERE r.id=p_registration_id
    RETURNING r.id,r.status,r.reviewed_by,r.reviewed_at;
  DELETE FROM private.registration_blocklist_acknowledgements a
    WHERE a.transaction_id=txid_current() AND a.event_id=p_event_id AND a.profile_id=v_reg.profile_id AND a.action='review';
END;
$$;

REVOKE ALL ON FUNCTION public.create_event_registration_checked(uuid,uuid,boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.register_event_series_checked(uuid,uuid,jsonb,uuid[],boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.review_event_registration_checked(uuid,uuid,uuid,text,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_event_registration_checked(uuid,uuid,boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.register_event_series_checked(uuid,uuid,jsonb,uuid[],boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.review_event_registration_checked(uuid,uuid,uuid,text,boolean) TO service_role;
