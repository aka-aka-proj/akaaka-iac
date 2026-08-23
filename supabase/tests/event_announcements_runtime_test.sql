BEGIN;

SELECT plan(10);

CREATE TEMP TABLE announcement_runtime_ids (
  host_id UUID,
  approved_id UUID,
  pending_id UUID,
  waitlisted_id UUID,
  cancelled_id UUID,
  event_id UUID,
  announcement_id UUID
);

INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT id, 'authenticated', 'authenticated', id::text || '@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()
FROM (
  VALUES
    ('00000000-0000-4000-8000-000000000101'::uuid),
    ('00000000-0000-4000-8000-000000000102'::uuid),
    ('00000000-0000-4000-8000-000000000103'::uuid),
    ('00000000-0000-4000-8000-000000000104'::uuid),
    ('00000000-0000-4000-8000-000000000105'::uuid)
) AS users(id);

INSERT INTO public.profiles (id, display_name, external_social_links)
SELECT id, 'Runtime ' || right(id::text, 3), '[{"url":"https://local.test"}]'::jsonb
FROM auth.users;

INSERT INTO public.events (
  id, creator_id, title, description, event_type, visibility_settings,
  start_time, lifecycle_status, publication_status
)
VALUES (
  '00000000-0000-4000-8000-000000000201',
  '00000000-0000-4000-8000-000000000101',
  'Private runtime event', 'runtime fixture', 'other',
  '{"type":"private"}'::jsonb, now() + interval '1 day', 'published', 'published'
);

INSERT INTO public.event_registrations (event_id, profile_id, status)
VALUES
  ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000102', 'approved'),
  ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000103', 'pending'),
  ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000104', 'waitlisted'),
  ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000105', 'cancelled');

INSERT INTO announcement_runtime_ids
VALUES (
  '00000000-0000-4000-8000-000000000101',
  '00000000-0000-4000-8000-000000000102',
  '00000000-0000-4000-8000-000000000103',
  '00000000-0000-4000-8000-000000000104',
  '00000000-0000-4000-8000-000000000105',
  '00000000-0000-4000-8000-000000000201',
  NULL
);

SELECT set_config('request.jwt.claim.sub', host_id::text, true)
FROM announcement_runtime_ids;
SET LOCAL ROLE authenticated;

SELECT lives_ok(
  $$SELECT public.create_event_announcement(
    '00000000-0000-4000-8000-000000000201', 'Runtime title', 'Runtime body', NULL, FALSE
  )$$,
  'host can create a draft through the constrained RPC'
);

SELECT id AS announcement_id
FROM public.event_announcements
WHERE event_id = '00000000-0000-4000-8000-000000000201'
\gset runtime_

SELECT lives_ok(
  format(
    $$SELECT public.publish_event_announcement(%L::uuid)$$,
    :'runtime_announcement_id'
  ),
  'host can publish the draft through the constrained RPC'
);

SELECT is(
  (SELECT count(*)::integer FROM public.event_announcements
   WHERE event_id = '00000000-0000-4000-8000-000000000201'),
  1,
  'host can read the published announcement for a private event'
);

SELECT set_config('request.jwt.claim.sub', profile_id::text, true)
FROM public.event_registrations
WHERE event_id = '00000000-0000-4000-8000-000000000201'
ORDER BY profile_id
LIMIT 1;

SELECT is(
  (SELECT count(*)::integer FROM public.event_announcements
   WHERE event_id = '00000000-0000-4000-8000-000000000201'),
  1,
  'approved registrant can read the private event announcement'
);

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000103', true);
SELECT is(
  (SELECT count(*)::integer FROM public.event_announcements
   WHERE event_id = '00000000-0000-4000-8000-000000000201'),
  1,
  'pending registrant can read the private event announcement'
);

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000104', true);
SELECT is(
  (SELECT count(*)::integer FROM public.event_announcements
   WHERE event_id = '00000000-0000-4000-8000-000000000201'),
  1,
  'waitlisted registrant can read the private event announcement'
);

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000105', true);
SELECT is(
  (SELECT count(*)::integer FROM public.event_announcements
   WHERE event_id = '00000000-0000-4000-8000-000000000201'),
  1,
  'cancelled registrant can read the private event announcement'
);

SET LOCAL ROLE postgres;
SELECT is(
  (SELECT count(*)::integer FROM public.notifications
   WHERE notification_type = 'event_announcement'
     AND event_announcement_id = :'runtime_announcement_id'::uuid),
  4,
  'all four registration states receive one in-app notification'
);

INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES (
  '00000000-0000-4000-8000-000000000102',
  '00000000-0000-4000-8000-000000000101'
);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000102', true);

SELECT is(
  (SELECT count(*)::integer FROM public.event_announcements
   WHERE event_id = '00000000-0000-4000-8000-000000000201'),
  0,
  'blocked registrant loses announcement access'
);

SET LOCAL ROLE postgres;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000101', true);
SELECT public.set_event_publication(
  '00000000-0000-4000-8000-000000000201', 'closed', NULL, NULL
);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000103', true);

SELECT is(
  (SELECT count(*)::integer FROM public.event_announcements
   WHERE event_id = '00000000-0000-4000-8000-000000000201'),
  0,
  'closed event removes announcement access'
);

SELECT * FROM finish();
ROLLBACK;
