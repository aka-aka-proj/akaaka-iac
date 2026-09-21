-- akaaka-iac#187 / akaaka-docs#207
-- Any change to poll options or eligible voters invalidates the whole ballot set.
-- A BEFORE trigger is intentional: it clears dependent votes before existing
-- option/voter guards and foreign keys evaluate the configuration mutation.

CREATE OR REPLACE FUNCTION public.reset_event_scheduling_poll_votes_on_configuration_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  target_poll_id UUID;
BEGIN
  target_poll_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.poll_id ELSE NEW.poll_id END;

  -- Do not interfere with ON DELETE CASCADE after the parent poll is gone.
  IF NOT EXISTS (
    SELECT 1 FROM public.event_scheduling_polls p WHERE p.id = target_poll_id
  ) THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;

  DELETE FROM public.event_scheduling_poll_votes v
  WHERE v.poll_id = target_poll_id;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

REVOKE ALL ON FUNCTION public.reset_event_scheduling_poll_votes_on_configuration_change() FROM PUBLIC;

CREATE TRIGGER auto_reset_event_scheduling_poll_option_votes
BEFORE INSERT OR UPDATE OR DELETE ON public.event_scheduling_poll_options
FOR EACH ROW EXECUTE FUNCTION public.reset_event_scheduling_poll_votes_on_configuration_change();

CREATE TRIGGER auto_reset_event_scheduling_poll_voter_votes
BEFORE INSERT OR UPDATE OR DELETE ON public.event_scheduling_poll_voters
FOR EACH ROW EXECUTE FUNCTION public.reset_event_scheduling_poll_votes_on_configuration_change();
