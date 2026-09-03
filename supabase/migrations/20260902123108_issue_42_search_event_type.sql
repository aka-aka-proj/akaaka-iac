-- Issue #42: keep server-side search semantics aligned with the canonical spec.
-- The existing function remains security-invoker and RLS-scoped; this adds the
-- event_type field to the same case-insensitive search term.
CREATE OR REPLACE FUNCTION public.search_events(
  p_search TEXT DEFAULT NULL,
  p_event_type TEXT DEFAULT NULL,
  p_location_region TEXT DEFAULT NULL,
  p_time_filter TEXT DEFAULT 'upcoming',
  p_creator_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
)
RETURNS SETOF public.events
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT e.*
  FROM public.events AS e
  WHERE (
    NULLIF(BTRIM(p_search), '') IS NULL
    OR e.title ILIKE '%' || BTRIM(p_search) || '%'
    OR COALESCE(e.description, '') ILIKE '%' || BTRIM(p_search) || '%'
    OR COALESCE(e.location_detail, '') ILIKE '%' || BTRIM(p_search) || '%'
    OR COALESCE(e.event_type, '') ILIKE '%' || BTRIM(p_search) || '%'
  )
  AND (NULLIF(BTRIM(p_event_type), '') IS NULL OR e.event_type ILIKE '%' || BTRIM(p_event_type) || '%')
  AND (NULLIF(BTRIM(p_location_region), '') IS NULL OR e.location_region::text = BTRIM(p_location_region))
  AND (
    COALESCE(p_time_filter, 'upcoming') = 'all'
    OR (p_time_filter = 'upcoming' AND e.start_time >= timezone('utc', now()))
    OR (p_time_filter = 'past' AND e.start_time < timezone('utc', now()))
  )
  AND (p_creator_id IS NULL OR e.creator_id = p_creator_id)
  ORDER BY e.start_time ASC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$;
