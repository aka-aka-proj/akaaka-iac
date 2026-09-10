-- Qualify outer membership columns: events.series_id is a recurring-event link.
-- Preserve owner-only, draft-only writes; no data, grants, or read-policy changes.
BEGIN;

DROP POLICY IF EXISTS event_series_membership_insert ON public.event_series_membership;
CREATE POLICY event_series_membership_insert
  ON public.event_series_membership
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.event_series AS es
      JOIN public.events AS e ON e.id = public.event_series_membership.event_id
      WHERE es.id = public.event_series_membership.series_id
        AND es.creator_id = auth.uid()
        AND es.lifecycle_status = 'draft'
        AND e.creator_id = auth.uid()
        AND e.lifecycle_status = 'draft'
    )
  );

DROP POLICY IF EXISTS event_series_membership_update ON public.event_series_membership;
CREATE POLICY event_series_membership_update
  ON public.event_series_membership
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.event_series AS es
      WHERE es.id = public.event_series_membership.series_id
        AND es.creator_id = auth.uid()
        AND es.lifecycle_status = 'draft'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.event_series AS es
      JOIN public.events AS e ON e.id = public.event_series_membership.event_id
      WHERE es.id = public.event_series_membership.series_id
        AND es.creator_id = auth.uid()
        AND es.lifecycle_status = 'draft'
        AND e.creator_id = auth.uid()
        AND e.lifecycle_status = 'draft'
    )
  );

COMMIT;
