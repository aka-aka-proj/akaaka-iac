BEGIN;

SELECT plan(9);

SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'notifications'
      AND column_name = 'event_series_id'
  ),
  'notifications stores the event series target'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.notifications'::regclass
      AND conname = 'notifications_notification_type_check'
      AND pg_get_constraintdef(oid) LIKE '%event_series_registration%'
  ),
  'notifications accepts event_series_registration'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'notifications_event_series_registration_target_unique'
  ),
  'series registration notifications have a series-aware unique index'
);

SELECT ok(
  pg_get_indexdef('public.notifications_follow_target_unique'::regclass)
    LIKE '%notification_type = ''new_follow''%',
  'follow notification uniqueness is scoped to new_follow'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.event_series_registrations'::regclass
      AND tgname = 'trg_notify_series_registration'
      AND NOT tgisinternal
  ),
  'approved series registrations have a notification trigger'
);

SET session_replication_role = replica;

INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES
  ('00000000-0000-4000-8000-000000000401', 'authenticated', 'authenticated', 'series-host@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('00000000-0000-4000-8000-000000000402', 'authenticated', 'authenticated', 'series-member@local.test', '{}'::jsonb, '{}'::jsonb, now(), now());

INSERT INTO public.profiles (id, display_name, external_social_links)
VALUES
  ('00000000-0000-4000-8000-000000000401', 'Series Host', '[{"url":"https://local.test/host"}]'::jsonb),
  ('00000000-0000-4000-8000-000000000402', 'Series Member', '[{"url":"https://local.test/member"}]'::jsonb);

INSERT INTO public.event_series (id, creator_id, title, lifecycle_status)
VALUES
  ('00000000-0000-4000-8000-000000000411', '00000000-0000-4000-8000-000000000401', 'First Series', 'published'),
  ('00000000-0000-4000-8000-000000000412', '00000000-0000-4000-8000-000000000401', 'Second Series', 'published');

SET session_replication_role = origin;

INSERT INTO public.event_series_registrations (series_id, profile_id, status, whole_series_registration)
VALUES ('00000000-0000-4000-8000-000000000411', '00000000-0000-4000-8000-000000000402', 'approved', true);

SELECT is(
  (SELECT count(*)::integer FROM public.notifications
   WHERE notification_type = 'event_series_registration'),
  1,
  'approved registration creates one notification'
);

SELECT is(
  (SELECT event_series_id FROM public.notifications
   WHERE notification_type = 'event_series_registration' LIMIT 1),
  '00000000-0000-4000-8000-000000000411'::uuid,
  'notification stores the registered series id'
);

INSERT INTO public.event_series_registrations (series_id, profile_id, status, whole_series_registration)
VALUES ('00000000-0000-4000-8000-000000000412', '00000000-0000-4000-8000-000000000402', 'approved', true);

SELECT is(
  (SELECT count(*)::integer FROM public.notifications
   WHERE notification_type = 'event_series_registration'),
  2,
  'same member can notify the same host for a second series'
);

INSERT INTO public.event_series_registrations (series_id, profile_id, status, whole_series_registration)
VALUES ('00000000-0000-4000-8000-000000000411', '00000000-0000-4000-8000-000000000402', 'pending', false);

SELECT is(
  (SELECT count(*)::integer FROM public.notifications
   WHERE notification_type = 'event_series_registration'),
  2,
  'pending registration does not create an approval notification'
);

SELECT * FROM finish();
ROLLBACK;
