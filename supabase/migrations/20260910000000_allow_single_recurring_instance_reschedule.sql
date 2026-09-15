-- Allow an authenticated owner to reschedule one future recurring-series row.
-- Batch schedule changes and privileged/service-role bypasses remain forbidden.
-- Canonical contract: docs/spec/features/events/012-recurring-instance-reschedule-spec.md

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

  IF NEW.series_id IS DISTINCT FROM OLD.series_id THEN
    RAISE EXCEPTION 'series member series_id may not change'
      USING ERRCODE = 'P0001';
  END IF;

  IF NEW.start_time IS DISTINCT FROM OLD.start_time THEN
    IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM OLD.creator_id THEN
      RAISE EXCEPTION 'series member start_time may only be changed by its owner'
        USING ERRCODE = '42501';
    END IF;
    IF OLD.start_time <= timezone('utc', now())
      OR NEW.start_time <= timezone('utc', now())
      OR OLD.lifecycle_status IN ('completed', 'archived', 'cancelled')
      OR NEW.lifecycle_status IN ('completed', 'archived', 'cancelled') THEN
      RAISE EXCEPTION 'only a future non-terminal series member may be rescheduled'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

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

CREATE OR REPLACE FUNCTION public.enforce_single_series_reschedule_statement()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  _rescheduled_count INTEGER;
BEGIN
  SELECT count(*)
  INTO _rescheduled_count
  FROM old_rows old_row
  JOIN new_rows new_row USING (id)
  WHERE new_row.start_time IS DISTINCT FROM old_row.start_time
    AND (
      old_row.series_id IS NOT NULL
      OR new_row.series_id IS NOT NULL
      OR EXISTS (SELECT 1 FROM public.events child WHERE child.series_id = old_row.id)
    );

  IF _rescheduled_count > 1 THEN
    RAISE EXCEPTION 'recurring instances must be rescheduled one row at a time'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_single_series_reschedule ON public.events;
CREATE TRIGGER trg_enforce_single_series_reschedule
  AFTER UPDATE ON public.events
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.enforce_single_series_reschedule_statement();
