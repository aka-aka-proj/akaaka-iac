-- Organizer-owned atomic reset for an open event scheduling poll.
-- Frontend confirmation is a UX safeguard; authorization is enforced here.
CREATE OR REPLACE FUNCTION public.reset_event_scheduling_poll_votes(p_poll_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  poll_row public.event_scheduling_polls;
BEGIN
  SELECT * INTO poll_row
  FROM public.event_scheduling_polls
  WHERE id = p_poll_id
  FOR UPDATE;

  IF poll_row.id IS NULL OR poll_row.creator_id <> auth.uid() THEN
    RAISE EXCEPTION 'poll not found or access denied' USING ERRCODE = '42501';
  END IF;

  IF poll_row.status <> 'open' THEN
    RAISE EXCEPTION 'poll is closed' USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM public.event_scheduling_poll_votes
  WHERE poll_id = p_poll_id;
END;
$$;

REVOKE ALL ON FUNCTION public.reset_event_scheduling_poll_votes(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reset_event_scheduling_poll_votes(UUID) TO authenticated;
