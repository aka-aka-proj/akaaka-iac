-- Expose only aggregate capacity for viewers who can read the event.
-- Registration and external guest rows remain protected by their existing RLS.

CREATE OR REPLACE FUNCTION public.get_event_capacity(p_event_id UUID)
RETURNS TABLE (
  approved_registration_count BIGINT,
  capacity_external_guest_count BIGINT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT
    (
      SELECT COUNT(*)
      FROM public.event_registrations er
      WHERE er.event_id = e.id
        AND er.status = 'approved'
    ) AS approved_registration_count,
    (
      SELECT COUNT(*)
      FROM public.event_external_guests eg
      WHERE eg.event_id = e.id
        AND eg.count_towards_capacity = TRUE
    ) AS capacity_external_guest_count
  FROM public.events e
  WHERE e.id = p_event_id
    AND (
      e.creator_id = (SELECT auth.uid())
      OR (
        e.lifecycle_status <> 'draft'
        AND e.publication_status = 'published'
        AND (
          COALESCE(e.visibility_settings ->> 'type', 'public') = 'public'
          OR (
            COALESCE(e.visibility_settings ->> 'type', '') = 'connections_only'
            AND (SELECT auth.uid()) IS NOT NULL
            AND EXISTS (
              SELECT 1
              FROM public.user_follows f1
              JOIN public.user_follows f2
                ON f2.follower_id = f1.followed_id
               AND f2.followed_id = f1.follower_id
              WHERE f1.follower_id = (SELECT auth.uid())
                AND f1.followed_id = e.creator_id
            )
          )
        )
      )
    );
$$;

REVOKE ALL ON FUNCTION public.get_event_capacity(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_capacity(UUID) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_capacity(UUID) IS
  'Returns aggregate approved registrations and capacity-counted external guests for a visible event; never returns participant data.';
