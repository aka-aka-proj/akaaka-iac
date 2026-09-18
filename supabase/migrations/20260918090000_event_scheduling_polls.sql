-- Event scheduling polls (akaaka-docs#207, akaaka-iac#184).
-- Poll membership is explicit. Ballots remain private; only aggregate counts
-- are exposed through get_event_scheduling_poll_results().

CREATE TABLE public.event_scheduling_polls (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  event_id UUID NOT NULL UNIQUE REFERENCES public.events(id) ON DELETE CASCADE,
  creator_id UUID NOT NULL REFERENCES public.profiles(id),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  closed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT event_scheduling_polls_closed_state CHECK (
    (status = 'open' AND closed_at IS NULL)
    OR (status = 'closed' AND closed_at IS NOT NULL)
  ),
  UNIQUE (id, creator_id)
);

CREATE TABLE public.event_scheduling_poll_options (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  poll_id UUID NOT NULL REFERENCES public.event_scheduling_polls(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('datetime', 'location')),
  starts_at TIMESTAMPTZ,
  location_label TEXT,
  sort_order INTEGER NOT NULL CHECK (sort_order >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT event_scheduling_poll_options_value CHECK (
    (kind = 'datetime' AND starts_at IS NOT NULL AND location_label IS NULL)
    OR
    (kind = 'location' AND starts_at IS NULL AND location_label IS NOT NULL
      AND location_label = btrim(location_label)
      AND char_length(location_label) BETWEEN 1 AND 200)
  ),
  UNIQUE (poll_id, id),
  UNIQUE (poll_id, sort_order)
);

CREATE UNIQUE INDEX event_scheduling_poll_options_datetime_unique
  ON public.event_scheduling_poll_options (poll_id, starts_at)
  WHERE kind = 'datetime';
CREATE UNIQUE INDEX event_scheduling_poll_options_location_unique
  ON public.event_scheduling_poll_options (poll_id, lower(location_label))
  WHERE kind = 'location';

CREATE TABLE public.event_scheduling_poll_voters (
  poll_id UUID NOT NULL REFERENCES public.event_scheduling_polls(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  PRIMARY KEY (poll_id, profile_id)
);

CREATE TABLE public.event_scheduling_poll_votes (
  poll_id UUID NOT NULL,
  option_id UUID NOT NULL,
  profile_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  PRIMARY KEY (poll_id, option_id, profile_id),
  FOREIGN KEY (poll_id, option_id)
    REFERENCES public.event_scheduling_poll_options(poll_id, id) ON DELETE CASCADE,
  FOREIGN KEY (poll_id, profile_id)
    REFERENCES public.event_scheduling_poll_voters(poll_id, profile_id) ON DELETE CASCADE
);

CREATE INDEX event_scheduling_poll_voters_profile_idx
  ON public.event_scheduling_poll_voters (profile_id, poll_id);
CREATE INDEX event_scheduling_poll_votes_option_idx
  ON public.event_scheduling_poll_votes (option_id);

CREATE OR REPLACE FUNCTION public.guard_event_scheduling_poll()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, extensions
AS $$
DECLARE
  owner_id UUID;
  event_state TEXT;
BEGIN
  SELECT creator_id, lifecycle_status INTO owner_id, event_state
  FROM public.events WHERE id = NEW.event_id;

  IF owner_id IS NULL OR event_state <> 'draft' OR NEW.creator_id <> owner_id THEN
    RAISE EXCEPTION 'scheduling polls require an owned draft event'
      USING ERRCODE = '23514';
  END IF;

  IF TG_OP = 'UPDATE' AND (
    NEW.event_id IS DISTINCT FROM OLD.event_id
    OR NEW.creator_id IS DISTINCT FROM OLD.creator_id
    OR OLD.status = 'closed'
  ) THEN
    RAISE EXCEPTION 'closed poll and poll ownership are immutable'
      USING ERRCODE = '23514';
  END IF;

  NEW.updated_at := timezone('utc', now());
  RETURN NEW;
END;
$$;

CREATE TRIGGER guard_event_scheduling_poll
BEFORE INSERT OR UPDATE ON public.event_scheduling_polls
FOR EACH ROW EXECUTE FUNCTION public.guard_event_scheduling_poll();

CREATE OR REPLACE FUNCTION public.guard_event_scheduling_poll_option()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE poll_state TEXT;
BEGIN
  SELECT status INTO poll_state FROM public.event_scheduling_polls
  WHERE id = COALESCE(NEW.poll_id, OLD.poll_id);
  -- ON DELETE CASCADE removes the poll before its children. Allow that
  -- database-owned cleanup path while continuing to reject user mutations.
  IF TG_OP = 'DELETE' AND poll_state IS NULL THEN RETURN OLD; END IF;
  IF poll_state IS DISTINCT FROM 'open' THEN
    RAISE EXCEPTION 'poll is closed' USING ERRCODE = 'P0001';
  END IF;
  IF TG_OP = 'INSERT' AND NEW.kind = 'datetime'
     AND NEW.starts_at <= timezone('utc', now()) THEN
    RAISE EXCEPTION 'datetime candidate must be in the future'
      USING ERRCODE = '23514';
  END IF;
  IF TG_OP = 'UPDATE' AND (
      NEW.poll_id IS DISTINCT FROM OLD.poll_id
      OR NEW.kind IS DISTINCT FROM OLD.kind
      OR NEW.starts_at IS DISTINCT FROM OLD.starts_at
      OR NEW.location_label IS DISTINCT FROM OLD.location_label
    ) AND EXISTS (
      SELECT 1 FROM public.event_scheduling_poll_votes v
      WHERE v.poll_id = OLD.poll_id AND v.option_id = OLD.id
    ) THEN
    RAISE EXCEPTION 'an option with votes cannot change canonical value'
      USING ERRCODE = '23514';
  END IF;
  IF TG_OP = 'DELETE' AND EXISTS (
      SELECT 1 FROM public.event_scheduling_poll_votes v
      WHERE v.poll_id = OLD.poll_id AND v.option_id = OLD.id
    ) THEN
    RAISE EXCEPTION 'an option with votes cannot be deleted'
      USING ERRCODE = '23514';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_event_scheduling_poll_option() FROM PUBLIC;

CREATE TRIGGER guard_event_scheduling_poll_option
BEFORE INSERT OR UPDATE OR DELETE ON public.event_scheduling_poll_options
FOR EACH ROW EXECUTE FUNCTION public.guard_event_scheduling_poll_option();

CREATE OR REPLACE FUNCTION public.guard_event_scheduling_poll_voter()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE poll_owner UUID; poll_state TEXT;
BEGIN
  SELECT creator_id, status INTO poll_owner, poll_state
  FROM public.event_scheduling_polls
  WHERE id = COALESCE(NEW.poll_id, OLD.poll_id);
  IF TG_OP = 'DELETE' AND poll_state IS NULL THEN RETURN OLD; END IF;
  IF poll_state IS DISTINCT FROM 'open' THEN
    RAISE EXCEPTION 'poll is closed' USING ERRCODE = 'P0001';
  END IF;
  IF TG_OP = 'UPDATE' AND (
    NEW.poll_id IS DISTINCT FROM OLD.poll_id
    OR NEW.profile_id IS DISTINCT FROM OLD.profile_id
  ) THEN
    RAISE EXCEPTION 'voter identity is immutable' USING ERRCODE = '23514';
  END IF;
  IF TG_OP <> 'DELETE' AND EXISTS (
    SELECT 1 FROM public.blocks b
    WHERE (b.blocker_id = poll_owner AND b.blocked_id = NEW.profile_id)
       OR (b.blocker_id = NEW.profile_id AND b.blocked_id = poll_owner)
  ) THEN
    RAISE EXCEPTION 'blocked profiles cannot be eligible voters'
      USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_event_scheduling_poll_voter() FROM PUBLIC;

CREATE TRIGGER guard_event_scheduling_poll_voter
BEFORE INSERT OR UPDATE OR DELETE ON public.event_scheduling_poll_voters
FOR EACH ROW EXECUTE FUNCTION public.guard_event_scheduling_poll_voter();

CREATE OR REPLACE FUNCTION public.guard_event_scheduling_poll_vote()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE poll_owner UUID; poll_state TEXT; voter_id UUID;
BEGIN
  voter_id := COALESCE(NEW.profile_id, OLD.profile_id);
  SELECT creator_id, status INTO poll_owner, poll_state
  FROM public.event_scheduling_polls
  WHERE id = COALESCE(NEW.poll_id, OLD.poll_id);
  IF TG_OP = 'DELETE' AND poll_state IS NULL THEN RETURN OLD; END IF;
  IF poll_state IS DISTINCT FROM 'open' THEN
    RAISE EXCEPTION 'poll is closed' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.blocks b
    WHERE (b.blocker_id = poll_owner AND b.blocked_id = voter_id)
       OR (b.blocker_id = voter_id AND b.blocked_id = poll_owner)
  ) THEN
    RAISE EXCEPTION 'blocked profiles cannot vote' USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'UPDATE' AND (
    NEW.poll_id IS DISTINCT FROM OLD.poll_id
    OR NEW.option_id IS DISTINCT FROM OLD.option_id
    OR NEW.profile_id IS DISTINCT FROM OLD.profile_id
  ) THEN
    RAISE EXCEPTION 'vote identity is immutable' USING ERRCODE = '23514';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_event_scheduling_poll_vote() FROM PUBLIC;

CREATE TRIGGER guard_event_scheduling_poll_vote
BEFORE INSERT OR UPDATE OR DELETE ON public.event_scheduling_poll_votes
FOR EACH ROW EXECUTE FUNCTION public.guard_event_scheduling_poll_vote();

ALTER TABLE public.event_scheduling_polls ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_scheduling_poll_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_scheduling_poll_voters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_scheduling_poll_votes ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.can_access_event_scheduling_poll(p_poll_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.event_scheduling_polls p
    LEFT JOIN public.event_scheduling_poll_voters v
      ON v.poll_id = p.id AND v.profile_id = auth.uid()
    WHERE p.id = p_poll_id
      AND (
        p.creator_id = auth.uid()
        OR (
          v.profile_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM public.blocks b
            WHERE (b.blocker_id = p.creator_id AND b.blocked_id = auth.uid())
               OR (b.blocker_id = auth.uid() AND b.blocked_id = p.creator_id)
          )
        )
      )
  );
$$;

CREATE OR REPLACE FUNCTION public.owns_event_scheduling_poll(p_poll_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.event_scheduling_polls p
    WHERE p.id = p_poll_id AND p.creator_id = auth.uid()
  );
$$;

REVOKE ALL ON FUNCTION public.can_access_event_scheduling_poll(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.owns_event_scheduling_poll(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_access_event_scheduling_poll(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owns_event_scheduling_poll(UUID) TO authenticated;

CREATE POLICY scheduling_polls_read ON public.event_scheduling_polls FOR SELECT TO authenticated
USING (public.can_access_event_scheduling_poll(id));
CREATE POLICY scheduling_polls_insert ON public.event_scheduling_polls FOR INSERT TO authenticated
WITH CHECK (creator_id = (SELECT auth.uid()));
CREATE POLICY scheduling_polls_update ON public.event_scheduling_polls FOR UPDATE TO authenticated
USING (creator_id = (SELECT auth.uid())) WITH CHECK (creator_id = (SELECT auth.uid()));
CREATE POLICY scheduling_polls_delete ON public.event_scheduling_polls FOR DELETE TO authenticated
USING (creator_id = (SELECT auth.uid()) AND status = 'open');

CREATE POLICY scheduling_options_read ON public.event_scheduling_poll_options FOR SELECT TO authenticated
USING (public.can_access_event_scheduling_poll(poll_id));
CREATE POLICY scheduling_options_owner_all ON public.event_scheduling_poll_options FOR ALL TO authenticated
USING (public.owns_event_scheduling_poll(poll_id))
WITH CHECK (public.owns_event_scheduling_poll(poll_id));

CREATE POLICY scheduling_voters_read ON public.event_scheduling_poll_voters FOR SELECT TO authenticated
USING (profile_id = (SELECT auth.uid()) OR public.owns_event_scheduling_poll(poll_id));
CREATE POLICY scheduling_voters_owner_all ON public.event_scheduling_poll_voters FOR ALL TO authenticated
USING (public.owns_event_scheduling_poll(poll_id))
WITH CHECK (public.owns_event_scheduling_poll(poll_id));

CREATE POLICY scheduling_votes_read_own ON public.event_scheduling_poll_votes FOR SELECT TO authenticated
USING (profile_id = (SELECT auth.uid()));
CREATE POLICY scheduling_votes_insert_own ON public.event_scheduling_poll_votes FOR INSERT TO authenticated
WITH CHECK (profile_id = (SELECT auth.uid()) AND public.can_access_event_scheduling_poll(poll_id));
CREATE POLICY scheduling_votes_delete_own ON public.event_scheduling_poll_votes FOR DELETE TO authenticated
USING (profile_id = (SELECT auth.uid()));

CREATE OR REPLACE FUNCTION public.get_event_scheduling_poll_results(p_poll_id UUID)
RETURNS TABLE(option_id UUID, vote_count BIGINT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_access_event_scheduling_poll(p_poll_id) THEN
    RAISE EXCEPTION 'poll not found or access denied' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT o.id, count(v.option_id)
    FROM public.event_scheduling_poll_options o
    LEFT JOIN public.event_scheduling_poll_votes v
      ON v.poll_id = o.poll_id AND v.option_id = o.id
    WHERE o.poll_id = p_poll_id
    GROUP BY o.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_event_scheduling_poll(
  p_poll_id UUID,
  p_datetime_option_id UUID DEFAULT NULL,
  p_location_option_id UUID DEFAULT NULL
)
RETURNS public.event_scheduling_polls
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE poll_row public.event_scheduling_polls; chosen_start TIMESTAMPTZ; chosen_location TEXT;
BEGIN
  SELECT * INTO poll_row FROM public.event_scheduling_polls
  WHERE id = p_poll_id FOR UPDATE;
  IF poll_row.id IS NULL OR poll_row.creator_id <> auth.uid() THEN
    RAISE EXCEPTION 'poll not found or access denied' USING ERRCODE = '42501';
  END IF;
  IF poll_row.status <> 'open' THEN RAISE EXCEPTION 'poll is closed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.events e WHERE e.id = poll_row.event_id AND e.creator_id = auth.uid() AND e.lifecycle_status = 'draft') THEN
    RAISE EXCEPTION 'event is no longer an editable draft' USING ERRCODE = '42501';
  END IF;
  IF (SELECT count(*) FROM public.event_scheduling_poll_options WHERE poll_id = p_poll_id) < 2 THEN
    RAISE EXCEPTION 'poll requires at least two candidates' USING ERRCODE = '23514';
  END IF;
  IF EXISTS (SELECT 1 FROM public.event_scheduling_poll_options WHERE poll_id=p_poll_id AND kind='datetime') THEN
    SELECT starts_at INTO chosen_start FROM public.event_scheduling_poll_options
    WHERE poll_id=p_poll_id AND id=p_datetime_option_id AND kind='datetime';
    IF chosen_start IS NULL THEN RAISE EXCEPTION 'a poll datetime option is required' USING ERRCODE='23514'; END IF;
  ELSIF p_datetime_option_id IS NOT NULL THEN
    RAISE EXCEPTION 'invalid datetime option' USING ERRCODE='23514';
  END IF;
  IF EXISTS (SELECT 1 FROM public.event_scheduling_poll_options WHERE poll_id=p_poll_id AND kind='location') THEN
    SELECT location_label INTO chosen_location FROM public.event_scheduling_poll_options
    WHERE poll_id=p_poll_id AND id=p_location_option_id AND kind='location';
    IF chosen_location IS NULL THEN RAISE EXCEPTION 'a poll location option is required' USING ERRCODE='23514'; END IF;
  ELSIF p_location_option_id IS NOT NULL THEN
    RAISE EXCEPTION 'invalid location option' USING ERRCODE='23514';
  END IF;
  UPDATE public.events SET
    start_time = COALESCE(chosen_start, start_time),
    location_detail = COALESCE(chosen_location, location_detail)
  WHERE id = poll_row.event_id;
  UPDATE public.event_scheduling_polls SET status='closed', closed_at=timezone('utc',now())
  WHERE id=p_poll_id RETURNING * INTO poll_row;
  RETURN poll_row;
END;
$$;

REVOKE ALL ON FUNCTION public.get_event_scheduling_poll_results(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.finalize_event_scheduling_poll(UUID, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_scheduling_poll_results(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_event_scheduling_poll(UUID, UUID, UUID) TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.event_scheduling_polls TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.event_scheduling_poll_options TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.event_scheduling_poll_voters TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.event_scheduling_poll_votes TO authenticated;
