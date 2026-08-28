BEGIN;

SELECT plan(3);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'event_series'
      AND policyname = 'event_series_public_read'
      AND roles = ARRAY['anon']::name[]
      AND qual = '(lifecycle_status = \'published\'::text)'
  ),
  'anonymous event-series policy only requires published lifecycle status'
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

SELECT * FROM finish();
ROLLBACK;
