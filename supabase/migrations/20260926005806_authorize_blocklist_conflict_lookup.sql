-- Run with the actual writer privileges before the definer conflict lookup.
-- Registration and approval must pass through the eligibility-checked endpoints.
CREATE FUNCTION private.authorize_registration_blocklist()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  -- Edge Functions enforce eligibility before the service-only RPC reaches here.
  -- Direct writers must not probe conflicts before constraints/RLS reject them.
  IF current_user IN ($r$anon$r$, $r$authenticated$r$) AND (
    TG_OP = $op$INSERT$op$
    OR (TG_OP = $op$UPDATE$op$ AND OLD.status = $s$pending$s$ AND NEW.status = $s$approved$s$)
  ) THEN
    RAISE EXCEPTION $e$forbidden$e$ USING ERRCODE = $e$P0001$e$;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.authorize_registration_blocklist() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER authorize_registration_blocklist BEFORE INSERT OR UPDATE OF status, event_id, profile_id
ON public.event_registrations FOR EACH ROW EXECUTE FUNCTION private.authorize_registration_blocklist();

