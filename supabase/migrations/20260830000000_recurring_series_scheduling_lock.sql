-- Series scheduling lock: recurring-series members cannot change their
-- start_time or recurrence_rule through any write path (owner PATCH, Data
-- API, or service-role batch writes). Only the recurrence_rule attribute
-- registration_deadline_offset_minutes may mutate (template sync).
--
-- Canonical rule: docs/spec/features/events/003-event-edit-spec.md (business
-- rules 13/14)
-- ADR: docs/adr/022-recurring-series-scope-editing.md
--
-- Invariants:
-- * A row belongs to a recurring series when series_id IS NOT NULL (child)
--   OR when another row references this row as its series_id (parent with
--   instances).
-- * Standalone events (no series relationship) are unaffected.
-- * start_time must never change for a series member.
-- * recurrence_rule may gain, lose, or change its
--   registration_deadline_offset_minutes attribute, but no other attribute
--   may differ from the current value.
-- * The trigger applies to ALL callers including service_role (no exemption).
-- * Template sync from update-recurring-series is the only legitimate path
--   that touches recurrence_rule across multiple members; the trigger allows
--   the JSONB-attribute-only diff so that path can synchronise the deadline
--   template without exception.

CREATE OR REPLACE FUNCTION public.enforce_series_scheduling_lock()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  _belongs_to_series BOOLEAN;
  _allowed_diff BOOLEAN;
BEGIN
  _belongs_to_series := (OLD.series_id IS NOT NULL)
    OR (NEW.series_id IS NOT NULL)
    OR EXISTS (SELECT 1 FROM public.events WHERE series_id = OLD.id);

  IF NOT _belongs_to_series THEN
    RETURN NEW;
  END IF;

  -- Also prevent changing series membership (which would allow bypassing the lock).
  IF NEW.series_id IS DISTINCT FROM OLD.series_id THEN
    RAISE EXCEPTION 'series member series_id may not change'
      USING ERRCODE = 'P0001';
  END IF;

  IF NEW.start_time IS DISTINCT FROM OLD.start_time THEN
    RAISE EXCEPTION 'series member start_time may not change'
      USING ERRCODE = 'P0001';
  END IF;

  -- Allow recurrence_rule change only when the sole difference is the
  -- registration_deadline_offset_minutes attribute. The JSONB `- text`
  -- operator removes the named key from the object (no-op if absent).
  IF NEW.recurrence_rule IS DISTINCT FROM OLD.recurrence_rule THEN
    _allowed_diff := (
      NEW.recurrence_rule - 'registration_deadline_offset_minutes'::text
    ) IS NOT DISTINCT FROM (
      OLD.recurrence_rule - 'registration_deadline_offset_minutes'::text
    );

    IF NOT _allowed_diff THEN
      RAISE EXCEPTION 'series member recurrence_rule may only change its registration_deadline_offset_minutes attribute'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_lock_series_scheduling ON public.events;

CREATE TRIGGER trg_lock_series_scheduling
  BEFORE UPDATE ON public.events
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_series_scheduling_lock();