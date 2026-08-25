BEGIN;

SELECT plan(6);

-- Contract suite for the recurring-series scheduling lock (ADR-022 / 003-event-edit-spec.md 業務規則 13-14):
-- 1) trigger exists on events table,
-- 2) function definition enforces the start_time lock,
-- 3) function definition enforces the recurrence_rule attribute-only diff rule,
-- 4) series child start_time change is rejected (runtime),
-- 5) series child recurrence_rule semantic change is rejected (runtime),
-- 6) recurrence_rule change limited to registration_deadline_offset_minutes is accepted.

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.events'::regclass
      AND tgname = 'trg_lock_series_scheduling'
      AND NOT tgisinternal
  ),
  'events carries the series scheduling lock trigger'
);

SELECT ok(
  (
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    WHERE p.oid = 'public.enforce_series_scheduling_lock()'::regprocedure
  ) LIKE '%series member start_time may not change%',
  'scheduling lock rejects series-member start_time changes'
);

SELECT ok(
  (
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    WHERE p.oid = 'public.enforce_series_scheduling_lock()'::regprocedure
  ) LIKE '%registration_deadline_offset_minutes%',
  'scheduling lock references the allowed-diff path for registration_deadline_offset_minutes'
);

-- Prepare a minimal profile and two events (parent + child with series_id).
-- Run inside a subtransaction so we can catch exceptions.

-- Bypass FK checks for test fixtures (auth.users lookup not needed in pgTAP).
SET session_replication_role = replica;

INSERT INTO public.profiles (id) VALUES ('00000000-0000-0000-0000-000000000001'::uuid);

INSERT INTO public.events (
  id, creator_id, title, start_time, location_region,
  lifecycle_status, attendance_fee_type, series_id, recurrence_rule
) VALUES (
  '00000000-0000-0000-0000-000000000010'::uuid,
  '00000000-0000-0000-0000-000000000001'::uuid,
  'Parent event', '2026-09-01T12:00:00Z', 'Online',
  'draft', 'free', NULL, '{"frequency":"weekly","interval":1,"days":["Mon"],"count":4,"timezone":"Asia/Taipei"}'::jsonb
);

INSERT INTO public.events (
  id, creator_id, title, start_time, location_region,
  lifecycle_status, attendance_fee_type, series_id
) VALUES (
  '00000000-0000-0000-0000-000000000011'::uuid,
  '00000000-0000-0000-0000-000000000001'::uuid,
  'Child event', '2026-09-07T12:00:00Z', 'Online',
  'draft', 'free', '00000000-0000-0000-0000-000000000010'::uuid
);

SELECT lives_ok(
  $$BEGIN
    UPDATE public.events
    SET start_time = '2026-09-07T14:00:00Z'
    WHERE id = '00000000-0000-0000-0000-000000000011'::uuid;
    RAISE EXCEPTION 'expected trigger to reject series child start_time change';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'series member start_time may not change' THEN
      -- expected, pass
    ELSE
      RAISE;
    END IF;
  END$$,
  'series child start_time change is rejected by the scheduling lock trigger'
);

SELECT lives_ok(
  $$BEGIN
    UPDATE public.events
    SET recurrence_rule = '{"frequency":"monthly","interval":1,"count":4,"timezone":"Asia/Taipei"}'::jsonb
    WHERE id = '00000000-0000-0000-0000-000000000011'::uuid;
    RAISE EXCEPTION 'expected trigger to reject series child recurrence_rule semantic change';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'series member recurrence_rule may only change its registration_deadline_offset_minutes attribute' THEN
      -- expected, pass
    ELSE
      RAISE;
    END IF;
  END$$,
  'series child recurrence_rule semantic change is rejected by the scheduling lock trigger'
);

SELECT lives_ok(
  $$BEGIN
    UPDATE public.events
    SET recurrence_rule = '{"frequency":"weekly","interval":1,"days":["Mon"],"count":4,"timezone":"Asia/Taipei","registration_deadline_offset_minutes":1440}'::jsonb
    WHERE id = '00000000-0000-0000-0000-000000000011'::uuid;
  EXCEPTION WHEN OTHERS THEN
    RAISE;
  END$$,
  'recurrence_rule change limited to registration_deadline_offset_minutes is accepted'
);

ROLLBACK;