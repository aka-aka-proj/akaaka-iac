-- Re-apply event-series public read policies for databases where the original
-- migration has already been recorded as applied.

DROP POLICY IF EXISTS event_series_public_read ON public.event_series;
CREATE POLICY event_series_public_read
  ON public.event_series
  FOR SELECT
  TO anon
  USING (lifecycle_status = 'published');

GRANT SELECT ON public.event_series TO anon, authenticated;

DROP POLICY IF EXISTS event_series_membership_select ON public.event_series_membership;
CREATE POLICY event_series_membership_select
  ON public.event_series_membership
  FOR SELECT
  TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.event_series es
      WHERE es.id = public.event_series_membership.series_id
        AND es.lifecycle_status = 'published'
    )
    AND EXISTS (
      SELECT 1
      FROM public.events e
      WHERE e.id = public.event_series_membership.event_id
        AND e.publication_status = 'published'
    )
  );

GRANT SELECT ON public.event_series_membership TO anon, authenticated;
