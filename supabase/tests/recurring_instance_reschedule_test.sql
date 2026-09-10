BEGIN;

SELECT plan(10);

SET session_replication_role = replica;

INSERT INTO public.profiles (id) VALUES
  ('00000000-0000-4000-8000-000000000801'::uuid),
  ('00000000-0000-4000-8000-000000000802'::uuid);

INSERT INTO public.events (
  id, creator_id, title, start_time, location_region,
  lifecycle_status, event_type, attendance_fee_type, series_id, recurrence_rule
) VALUES
  ('00000000-0000-4000-8000-000000000810', '00000000-0000-4000-8000-000000000801', 'Parent', '2099-01-01T12:00:00Z', 'Online', 'published', '{}', 'free', NULL, '{"frequency":"weekly","count":3}'),
  ('00000000-0000-4000-8000-000000000811', '00000000-0000-4000-8000-000000000801', 'Child one', '2099-01-08T12:00:00Z', 'Online', 'published', '{}', 'free', '00000000-0000-4000-8000-000000000810', '{"frequency":"weekly","count":3}'),
  ('00000000-0000-4000-8000-000000000812', '00000000-0000-4000-8000-000000000801', 'Child two', '2099-01-15T12:00:00Z', 'Online', 'published', '{}', 'free', '00000000-0000-4000-8000-000000000810', '{"frequency":"weekly","count":3}'),
  ('00000000-0000-4000-8000-000000000813', '00000000-0000-4000-8000-000000000801', 'Terminal child', '2099-01-22T12:00:00Z', 'Online', 'cancelled', '{}', 'free', '00000000-0000-4000-8000-000000000810', '{"frequency":"weekly","count":3}');

SET session_replication_role = origin;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000801', true);

SELECT lives_ok(
  $$UPDATE public.events SET start_time = '2099-01-09T12:00:00Z' WHERE id = '00000000-0000-4000-8000-000000000811'$$,
  'owner can reschedule one future non-terminal recurring instance'
);

SELECT is(
  (SELECT start_time FROM public.events WHERE id = '00000000-0000-4000-8000-000000000812')::text,
  '2099-01-15 12:00:00+00',
  'sibling start_time remains unchanged'
);

SELECT is(
  (SELECT start_time FROM public.events WHERE id = '00000000-0000-4000-8000-000000000810')::text,
  '2099-01-01 12:00:00+00',
  'parent start_time remains unchanged'
);

SELECT is(
  (SELECT series_id FROM public.events WHERE id = '00000000-0000-4000-8000-000000000811')::text,
  '00000000-0000-4000-8000-000000000810',
  'series_id remains unchanged'
);

SELECT is(
  (SELECT recurrence_rule FROM public.events WHERE id = '00000000-0000-4000-8000-000000000811'),
  '{"count": 3, "frequency": "weekly"}'::jsonb,
  'recurrence_rule remains unchanged'
);

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000802', true);
SELECT throws_ok(
  $$UPDATE public.events SET start_time = '2099-01-10T12:00:00Z' WHERE id = '00000000-0000-4000-8000-000000000811'$$,
  '42501',
  'series member start_time may only be changed by its owner',
  'non-owner cannot reschedule a recurring instance'
);

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000801', true);
SELECT throws_ok(
  $$UPDATE public.events SET start_time = '2020-01-01T12:00:00Z' WHERE id = '00000000-0000-4000-8000-000000000811'$$,
  'P0001',
  'only a future non-terminal series member may be rescheduled',
  'owner cannot move a recurring instance into the past'
);

SELECT throws_ok(
  $$UPDATE public.events SET start_time = '2099-01-23T12:00:00Z' WHERE id = '00000000-0000-4000-8000-000000000813'$$,
  'P0001',
  'only a future non-terminal series member may be rescheduled',
  'terminal recurring instance cannot be rescheduled'
);

SELECT throws_ok(
  $$UPDATE public.events SET start_time = start_time + interval '1 hour' WHERE series_id = '00000000-0000-4000-8000-000000000810' AND lifecycle_status = 'published'$$,
  'P0001',
  'recurring instances must be rescheduled one row at a time',
  'one statement cannot reschedule multiple recurring instances'
);

SELECT set_config('request.jwt.claim.sub', '', true);
SELECT throws_ok(
  $$UPDATE public.events SET start_time = '2099-01-10T12:00:00Z' WHERE id = '00000000-0000-4000-8000-000000000811'$$,
  '42501',
  'series member start_time may only be changed by its owner',
  'service-role style write without an owner identity cannot reschedule an instance'
);

ROLLBACK;
