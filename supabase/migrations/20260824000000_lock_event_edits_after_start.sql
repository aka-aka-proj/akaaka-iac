-- Event edit lock: organizers can no longer edit event content once a
-- non-draft event has started or reached a terminal lifecycle state.
--
-- Canonical rule: docs/spec/features/events/003-event-edit-spec.md
-- RLS intent matrix: docs/spec/security/001-rls-policy-matrix.md
--
-- Invariants:
-- * `draft` events are never public and stay editable regardless of start_time,
--   so an abandoned draft whose start_time has passed can still be fixed.
-- * Terminal states (`completed`, `archived`, `cancelled`) are immutable.
-- * WITH CHECK mirrors USING so an owner cannot move start_time into the past
--   to dodge the lock in a single UPDATE.
-- * Publication control (`set_event_publication`) is SECURITY DEFINER and is
--   unaffected: hosts may still unpublish a started event.

DROP POLICY IF EXISTS events_update_owner ON public.events;

CREATE POLICY events_update_owner ON public.events FOR UPDATE TO authenticated
USING (
  creator_id = auth.uid()
  AND lifecycle_status NOT IN ('completed', 'archived', 'cancelled')
  AND (lifecycle_status = 'draft' OR start_time > timezone('utc', now()))
)
WITH CHECK (
  creator_id = auth.uid()
  AND lifecycle_status NOT IN ('completed', 'archived', 'cancelled')
  AND (lifecycle_status = 'draft' OR start_time > timezone('utc', now()))
);
