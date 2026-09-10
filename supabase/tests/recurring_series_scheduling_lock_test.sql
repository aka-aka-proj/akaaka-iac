BEGIN;

SELECT plan(5);

-- Contract suite for the recurring-series scheduling lock (ADR-022 / 003-event-edit-spec.md 業務規則 13-14):
-- 1) trigger exists on events table,
-- 2) function definition enforces owner-only start_time changes,
-- 3) function definition enforces the recurrence_rule attribute-only diff rule,
-- 4) recurrence_rule change limited to registration_deadline_offset_minutes is accepted.

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
  ) LIKE '%start_time may only be changed by its owner%',
  'scheduling lock limits series-member start_time changes to the owner'
);

SELECT ok(
  (
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    WHERE p.oid = 'public.enforce_series_scheduling_lock()'::regprocedure
  ) LIKE '%registration_deadline_offset_minutes%',
  'scheduling lock references the allowed-diff path for registration_deadline_offset_minutes'
);

-- Setup: create minimal profile and two events (parent + child with series_id).
-- Bypass FK checks for test fixtures (auth.users lookup not needed in pgTAP),
-- then restore origin so the scheduling-lock trigger fires on updates.
SET session_replication_role = replica;

INSERT INTO public.profiles (id) VALUES ('00000000-0000-0000-0000-000000000001'::uuid);

INSERT INTO public.events (
  id, creator_id, title, start_time, location_region,
  lifecycle_status, event_type, attendance_fee_type, series_id, recurrence_rule
) VALUES (
  '00000000-0000-0000-0000-000000000010'::uuid,
  '00000000-0000-0000-0000-000000000001'::uuid,
  'Parent event', '2026-09-01T12:00:00Z', 'Online',
  'draft', '{}'::text[], 'free', NULL, '{"frequency":"weekly","interval":1,"days":["Mon"],"count":4,"timezone":"Asia/Taipei"}'::jsonb
);

INSERT INTO public.events (
  id, creator_id, title, start_time, location_region,
  lifecycle_status, event_type, attendance_fee_type, series_id, recurrence_rule
) VALUES (
  '00000000-0000-0000-0000-000000000011'::uuid,
  '00000000-0000-0000-0000-000000000001'::uuid,
  'Child event', '2026-09-07T12:00:00Z', 'Online',
  'draft', '{}'::text[], 'free', '00000000-0000-0000-0000-000000000010'::uuid,
  '{"frequency":"weekly","interval":1,"days":["Mon"],"count":4,"timezone":"Asia/Taipei"}'::jsonb
);

SET session_replication_role = origin;

SELECT throws_ok(
  $$UPDATE public.events SET recurrence_rule = '{"frequency":"monthly","interval":1,"count":4,"timezone":"Asia/Taipei"}'::jsonb WHERE id = '00000000-0000-0000-0000-000000000011'::uuid$$,
  'P0001',
  'series member recurrence_rule may only change its registration_deadline_offset_minutes attribute',
  'series child recurrence_rule semantic change is rejected by the scheduling lock trigger'
);

SELECT lives_ok(
  $$UPDATE public.events SET recurrence_rule = '{"frequency":"weekly","interval":1,"days":["Mon"],"count":4,"timezone":"Asia/Taipei","registration_deadline_offset_minutes":1440}'::jsonb WHERE id = '00000000-0000-0000-0000-000000000011'::uuid$$,
  'recurrence_rule change limited to registration_deadline_offset_minutes is accepted'
);

ROLLBACK;
