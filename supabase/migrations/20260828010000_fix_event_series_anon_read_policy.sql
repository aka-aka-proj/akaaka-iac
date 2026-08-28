-- Allow anonymous clients to read published event series without requiring
-- access to the profiles table used by the old redundant policy predicate.

DROP POLICY IF EXISTS event_series_public_read ON public.event_series;
CREATE POLICY event_series_public_read
  ON public.event_series
  FOR SELECT
  TO anon
  USING (lifecycle_status = 'published');
