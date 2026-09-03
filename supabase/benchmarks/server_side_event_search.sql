-- Issue #42 local benchmark harness.
-- Run with: supabase db query --local --file supabase/benchmarks/server_side_event_search.sql
-- The fixture is rolled back and must never be run against staging/production.
BEGIN;

SET session_replication_role = replica;

INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES
  ('00000000-0000-4300-8000-000000000101', 'authenticated', 'authenticated', 'benchmark-viewer@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('00000000-0000-4300-8000-000000000102', 'authenticated', 'authenticated', 'benchmark-host@local.test', '{}'::jsonb, '{}'::jsonb, now(), now());

INSERT INTO public.profiles (id, display_name, external_social_links)
VALUES
  ('00000000-0000-4300-8000-000000000101', 'Benchmark viewer', '[{"url":"https://local.test"}]'::jsonb),
  ('00000000-0000-4300-8000-000000000102', 'Benchmark host', '[{"url":"https://local.test"}]'::jsonb);

INSERT INTO public.events (
  id, creator_id, title, description, event_type, visibility_settings,
  start_time, lifecycle_status, publication_status
)
SELECT
  ('00000000-0000-4300-8000-' || lpad((200 + n)::text, 12, '0'))::uuid,
  '00000000-0000-4300-8000-000000000102'::uuid,
  CASE n
    WHEN 1 THEN '台北中文交流'
    WHEN 2 THEN '高雄中文讀書會'
    WHEN 3 THEN '繁體中文工作坊'
    ELSE 'Taipei community meetup'
  END,
  'Issue 42 benchmark fixture',
  CASE WHEN n = 3 THEN '文化實作' ELSE 'social' END,
  '{"type":"public"}'::jsonb,
  now() + (n || ' days')::interval,
  'published',
  'published'
FROM generate_series(1, 4) AS series(n);

SET session_replication_role = origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4300-8000-000000000101', true);

SELECT 'term=中文' AS benchmark_case;
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM public.search_events('中文', NULL, NULL, 'all', NULL, 50, 0);

SELECT 'term=文化實作' AS benchmark_case;
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM public.search_events('文化實作', NULL, NULL, 'all', NULL, 50, 0);

SELECT 'term=Taipei' AS benchmark_case;
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM public.search_events('Taipei', NULL, NULL, 'all', NULL, 50, 0);

ROLLBACK;
