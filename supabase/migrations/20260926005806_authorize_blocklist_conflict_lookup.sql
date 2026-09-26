-- Run with the actual writer privileges before the definer conflict lookup.
-- This SELECT deliberately uses event RLS, so unauthorized writes cannot probe peers.
CREATE FUNCTION private.authorize_registration_blocklist()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  IF current_user IN ('anon', 'authenticated') AND (
    (TG_OP = 'INSERT' AND NEW.status IN ('pending','approved','waitlisted','cancellation_pending','cancellation_rejected'))
    OR (TG_OP = 'UPDATE' AND OLD.status = 'pending' AND NEW.status = 'approved')
  ) THEN
    IF TG_OP = 'INSERT' THEN
      IF NEW.profile_id IS DISTINCT FROM auth.uid() OR NOT EXISTS (
        SELECT 1 FROM public.events e WHERE e.id = NEW.event_id
      ) THEN
        RAISE EXCEPTION 'forbidden' USING ERRCODE = 'P0001';
      END IF;
    ELSIF NOT EXISTS (
      SELECT 1 FROM public.events e WHERE e.id = NEW.event_id AND e.creator_id = auth.uid()
    ) THEN
      RAISE EXCEPTION 'forbidden' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.authorize_registration_blocklist() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER authorize_registration_blocklist BEFORE INSERT OR UPDATE OF status, event_id, profile_id
ON public.event_registrations FOR EACH ROW EXECUTE FUNCTION private.authorize_registration_blocklist();

