-- Series owners must be able to read their draft memberships while editing.
-- Public readers retain access only to published series memberships.
DROP POLICY IF EXISTS event_series_membership_select ON public.event_series_membership;

CREATE POLICY event_series_membership_select
  ON public.event_series_membership
  FOR SELECT
  TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.event_series AS es
      WHERE es.id = public.event_series_membership.series_id
        AND (
          es.lifecycle_status = 'published'
          OR (es.lifecycle_status = 'draft' AND es.creator_id = (SELECT auth.uid()))
        )
    )
    AND EXISTS (
      SELECT 1
      FROM public.events AS e
      WHERE e.id = public.event_series_membership.event_id
        AND (
          e.publication_status = 'published'
          OR e.creator_id = (SELECT auth.uid())
        )
    )
  );
