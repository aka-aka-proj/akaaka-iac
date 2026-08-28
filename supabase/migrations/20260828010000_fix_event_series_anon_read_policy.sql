-- Allow anonymous clients to read published event series without requiring
-- access to the profiles table used by the old redundant policy predicate.

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
      JOIN public.events e ON e.id = event_id
      WHERE es.id = series_id
        AND es.lifecycle_status = 'published'
        AND e.publication_status = 'published'
    )
  );

GRANT SELECT ON public.event_series_membership TO anon, authenticated;
