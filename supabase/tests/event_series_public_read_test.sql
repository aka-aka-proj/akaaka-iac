BEGIN;

SELECT plan(5);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'event_series'
      AND policyname = 'event_series_public_read'
      AND roles = ARRAY['anon']::name[]
      AND qual LIKE '%lifecycle_status%'
      AND qual LIKE '%published%'
      AND qual NOT LIKE '%profiles%'
  ),
  'anonymous event-series policy only requires published lifecycle status'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'event_series_membership'
      AND policyname = 'event_series_membership_select'
      AND roles = ARRAY['anon', 'authenticated']::name[]
      AND qual LIKE '%event_series%'
      AND qual LIKE '%lifecycle_status%'
      AND qual LIKE '%publication_status%'
  ),
  'anonymous membership policy requires a published series and event'
);

SET session_replication_role = replica;

INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES ('00000000-0000-4000-8000-000000000451', 'authenticated', 'authenticated', 'series-public@local.test', '{}'::jsonb, '{}'::jsonb, now(), now());

INSERT INTO public.profiles (id, display_name, external_social_links)
VALUES ('00000000-0000-4000-8000-000000000451', 'Public Series Host', '[{"url":"https://local.test/series-host"}]'::jsonb);

INSERT INTO public.event_series (id, creator_id, title, lifecycle_status)
VALUES
  ('00000000-0000-4000-8000-000000000461', '00000000-0000-4000-8000-000000000451', 'Published Series', 'published'),
  ('00000000-0000-4000-8000-000000000462', '00000000-0000-4000-8000-000000000451', 'Draft Series', 'draft');

INSERT INTO public.events (id, creator_id, title, event_type, start_time, publication_status, lifecycle_status)
VALUES
  ('00000000-0000-4000-8000-000000000471', '00000000-0000-4000-8000-000000000451', 'Published Event', 'social', now() + interval '1 day', 'published', 'published'),
  ('00000000-0000-4000-8000-000000000472', '00000000-0000-4000-8000-000000000451', 'Closed Event', 'social', now() + interval '2 days', 'closed', 'published');

INSERT INTO public.event_series_membership (series_id, event_id, position)
VALUES
  ('00000000-0000-4000-8000-000000000461', '00000000-0000-4000-8000-000000000471', 1),
  ('00000000-0000-4000-8000-000000000462', '00000000-0000-4000-8000-000000000472', 1);

SET session_replication_role = origin;
SET LOCAL ROLE anon;

SELECT is(
  (SELECT count(*)::integer FROM public.event_series),
  1,
  'anonymous clients can read published series without profiles table access'
);

SELECT is(
  (SELECT count(*)::integer FROM public.event_series WHERE lifecycle_status = 'draft'),
  0,
  'anonymous clients cannot read draft series'
);

SELECT is(
  (SELECT count(*)::integer FROM public.event_series_membership),
  1,
  'anonymous clients can read membership only for published series and events'
);

SELECT * FROM finish();
ROLLBACK;
