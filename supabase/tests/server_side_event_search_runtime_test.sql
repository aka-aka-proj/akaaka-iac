BEGIN;

SELECT plan(10);

-- Keep the fixture isolated and deterministic. Triggers are disabled only while
-- creating auth/profile/event rows; RLS is restored before the runtime probes.
SET session_replication_role = replica;

INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES
  ('00000000-0000-4200-8000-000000000101', 'authenticated', 'authenticated', 'search-viewer@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('00000000-0000-4200-8000-000000000102', 'authenticated', 'authenticated', 'search-public@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('00000000-0000-4200-8000-000000000103', 'authenticated', 'authenticated', 'search-private@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('00000000-0000-4200-8000-000000000104', 'authenticated', 'authenticated', 'search-connection@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('00000000-0000-4200-8000-000000000105', 'authenticated', 'authenticated', 'search-blocked@local.test', '{}'::jsonb, '{}'::jsonb, now(), now());

INSERT INTO public.profiles (id, display_name, external_social_links)
SELECT id, 'Search fixture ' || right(id::text, 3), '[{"url":"https://local.test"}]'::jsonb
FROM auth.users
WHERE id::text LIKE '00000000-0000-4200-8000-0000000001%';

INSERT INTO public.events (
  id, creator_id, title, description, event_type, visibility_settings,
  start_time, lifecycle_status, publication_status
)
VALUES
  ('00000000-0000-4200-8000-000000000201', '00000000-0000-4200-8000-000000000102', '台北中文聚會', '繁體中文搜尋 fixture', 'social', '{"type":"public"}'::jsonb, now() + interval '1 day', 'published', 'published'),
  ('00000000-0000-4200-8000-000000000202', '00000000-0000-4200-8000-000000000102', '公開文化活動', 'event type search fixture', '文化實作', '{"type":"public"}'::jsonb, now() + interval '2 days', 'published', 'published'),
  ('00000000-0000-4200-8000-000000000203', '00000000-0000-4200-8000-000000000103', '草稿活動', 'draft fixture', 'social', '{"type":"public"}'::jsonb, now() + interval '3 days', 'draft', 'closed'),
  ('00000000-0000-4200-8000-000000000204', '00000000-0000-4200-8000-000000000103', '私人活動', 'private fixture', 'social', '{"type":"private"}'::jsonb, now() + interval '4 days', 'published', 'published'),
  ('00000000-0000-4200-8000-000000000205', '00000000-0000-4200-8000-000000000104', '連線活動', 'connections fixture', 'social', '{"type":"connections_only"}'::jsonb, now() + interval '5 days', 'published', 'published'),
  ('00000000-0000-4200-8000-000000000206', '00000000-0000-4200-8000-000000000105', '被封鎖公開活動', 'block fixture', 'social', '{"type":"public"}'::jsonb, now() + interval '6 days', 'published', 'published');

INSERT INTO public.user_follows (follower_id, followed_id)
VALUES
  ('00000000-0000-4200-8000-000000000101', '00000000-0000-4200-8000-000000000104'),
  ('00000000-0000-4200-8000-000000000104', '00000000-0000-4200-8000-000000000101');

INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('00000000-0000-4200-8000-000000000101', '00000000-0000-4200-8000-000000000105');

SET session_replication_role = origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4200-8000-000000000101', true);

SELECT is(
  (SELECT count(*)::integer FROM public.search_events(NULL, NULL, NULL, 'all', NULL, 50, 0)),
  3,
  'authenticated search returns public and mutual-connection events only'
);

SELECT is(
  (SELECT count(*)::integer FROM public.search_events('中文', NULL, NULL, 'all', NULL, 50, 0)),
  1,
  'Chinese substring search matches the representative fixture'
);

SELECT is(
  (SELECT count(*)::integer FROM public.search_events('文化實作', NULL, NULL, 'all', NULL, 50, 0)),
  1,
  'search term matches event_type as well as text fields'
);

SELECT is(
  (SELECT count(*)::integer FROM public.search_events(NULL, NULL, NULL, 'upcoming', NULL, 50, 0)),
  3,
  'upcoming filter applies before the returned page'
);

SELECT is(
  (SELECT count(*)::integer FROM public.search_events('草稿', NULL, NULL, 'all', NULL, 50, 0)),
  0,
  'draft event remains hidden from a non-owner searcher'
);

SELECT is(
  (SELECT count(*)::integer FROM public.search_events('私人', NULL, NULL, 'all', NULL, 50, 0)),
  0,
  'private event remains hidden from an unregistered searcher'
);

SELECT is(
  (SELECT count(*)::integer FROM public.search_events('連線', NULL, NULL, 'all', NULL, 50, 0)),
  1,
  'mutual-follow connection event is visible'
);

SELECT is(
  (SELECT count(*)::integer FROM public.search_events('被封鎖', NULL, NULL, 'all', NULL, 50, 0)),
  0,
  'blocked creator event is hidden'
);

SELECT is(
  (SELECT count(*)::integer FROM public.search_events(NULL, NULL, NULL, 'all', NULL, 1, 1)),
  1,
  'limit and offset are applied to the RLS-filtered result set'
);

SELECT is(
  (SELECT count(*)::integer FROM public.search_events(NULL, NULL, NULL, 'all', '00000000-0000-4200-8000-000000000102'::uuid, 50, 0)),
  2,
  'creator filter returns only the visible creator-owned fixtures'
);

SELECT * FROM finish();
ROLLBACK;
