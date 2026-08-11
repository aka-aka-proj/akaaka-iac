ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS attendance_fee_type TEXT NOT NULL DEFAULT 'free',
  ADD COLUMN IF NOT EXISTS attendance_fee_amount INTEGER;

ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_attendance_fee_type_check,
  DROP CONSTRAINT IF EXISTS events_attendance_fee_consistency;

ALTER TABLE public.events
  ADD CONSTRAINT events_attendance_fee_type_check
    CHECK (attendance_fee_type IN ('free', 'fixed', 'see_description')),
  ADD CONSTRAINT events_attendance_fee_consistency
    CHECK (
      (attendance_fee_type = 'fixed' AND attendance_fee_amount > 0)
      OR (attendance_fee_type IN ('free', 'see_description') AND attendance_fee_amount IS NULL)
    );
