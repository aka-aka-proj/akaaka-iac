BEGIN;

SELECT plan(11);

-- Contract: the atomic RPC is an authenticated-owner browser API only.
SELECT ok(
  has_function_privilege('authenticated', 'public.update_and_publish_announcement(uuid,text,text)', 'EXECUTE'),
  'authenticated may execute update_and_publish_announcement'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.update_and_publish_announcement(uuid,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.update_and_publish_announcement(uuid,text,text)', 'EXECUTE'),
  'anon and service_role do not receive update_and_publish_announcement'
);

SELECT ok(
  (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = 'public.update_and_publish_announcement(uuid,text,text)'::regprocedure),
  'update_and_publish_announcement is security definer'
);

SELECT ok(
  (SELECT p.proconfig @> ARRAY['search_path=public, extensions']
   FROM pg_proc p WHERE p.oid = 'public.update_and_publish_announcement(uuid,text,text)'::regprocedure),
  'update_and_publish_announcement fixes its search path'
);

-- Fixtures: host + four registrants on a published native event.
INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT id, 'authenticated', 'authenticated', id::text || '@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()
FROM (
  VALUES
    ('00000000-0000-4000-8000-000000000501'::uuid),
    ('00000000-0000-4000-8000-000000000502'::uuid),
    ('00000000-0000-4000-8000-000000000503'::uuid),
    ('00000000-0000-4000-8000-000000000504'::uuid),
    ('00000000-0000-4000-8000-000000000505'::uuid)
) AS users(id);

INSERT INTO public.profiles (id, display_name, external_social_links)
SELECT id, 'Atomic ' || right(id::text, 3), '[{"url":"https://local.test"}]'::jsonb
FROM auth.users;

INSERT INTO public.events (
  id, creator_id, title, description, event_type, visibility_settings,
  start_time, lifecycle_status, publication_status
)
VALUES (
  '00000000-0000-4000-8000-000000000601',
  '00000000-0000-4000-8000-000000000501',
  'Atomic event', 'fixture', 'other',
  '{"type":"private"}'::jsonb, now() + interval '1 day', 'published', 'published'
);

INSERT INTO public.event_registrations (event_id, profile_id, status)
VALUES
  ('00000000-0000-4000-8000-000000000601', '00000000-0000-4000-8000-000000000502', 'approved'),
  ('00000000-0000-4000-8000-000000000601', '00000000-0000-4000-8000-000000000503', 'pending');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000501', true);

-- Scheduled announcement with a future publish_at and original content,
-- created through the controlled RPC (direct table writes are trigger-blocked).
SELECT lives_ok(
  $$SELECT public.create_event_announcement(
    '00000000-0000-4000-8000-000000000601'::uuid,
    '原始標題', '原始內文',
    now() + interval '2 days', false
  )$$,
  'host created a scheduled announcement through the controlled RPC'
);

-- 1. Happy path: edit + publish in one call.
SELECT lives_ok(
  $$SELECT public.update_and_publish_announcement(
    (SELECT id FROM public.event_announcements WHERE title = '原始標題'),
    '新標題', '新內文'
  )$$,
  'owner can apply edits and publish in a single atomic RPC'
);

SELECT ok(
  (SELECT status = 'published' AND title = '新標題' AND body_markdown = '新內文'
     AND publish_at IS NULL AND published_at IS NOT NULL
     FROM public.event_announcements WHERE title = '新標題'),
  'announcement ends published with the edited content and no schedule'
);

SELECT is(
  (SELECT count(DISTINCT recipient_profile_id)::integer
     FROM public.notifications n
     JOIN public.event_announcements a ON a.id = n.event_announcement_id
    WHERE a.title = '新標題'),
  2,
  'notification fan-out happened exactly once for both registrants'
);

-- 2. Atomicity under failure: publishing a second announcement within the
--    12-hour window must roll the EDIT back too — original schedule and
--    content survive untouched (frontend#73 regression).
SELECT lives_ok(
  $$SELECT public.create_event_announcement(
    '00000000-0000-4000-8000-000000000601'::uuid,
    '排程標題', '排程內文',
    now() + interval '3 days', false
  )$$,
  'second scheduled announcement created for the frequency-conflict scenario'
);

SELECT throws_ok(
  $$SELECT public.update_and_publish_announcement(
    (SELECT id FROM public.event_announcements WHERE title = '排程標題'),
    '被回滾的標題', '被回滾的內文'
  )$$,
  'event announcement frequency limit exceeded',
  '12-hour frequency violation aborts the combined edit+publish'
);

SELECT ok(
  (SELECT status = 'scheduled' AND title = '排程標題' AND body_markdown = '排程內文'
     AND published_at IS NULL
     AND publish_at > now() + interval '2 days'
     FROM public.event_announcements WHERE title = '排程標題'),
  'failed atomic call preserved the original schedule and content with no draft intermediate state'
);

-- 3. Non-owner gets rejected and nothing changes.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000504', true);

SELECT throws_ok(
  $$SELECT public.update_and_publish_announcement(
    (SELECT id FROM public.event_announcements WHERE title = '排程標題'),
    '入侵者標題', '入侵者內文'
  )$$,
  'announcement not found or immutable',
  'non-owner cannot edit+publish someone else''s announcement'
);

SELECT ok(
  (SELECT title = '排程標題' AND status = 'scheduled'
     FROM public.event_announcements WHERE title = '排程標題'),
  'non-owner attempt left no writes behind'
);

-- 4. Already-published announcements are immutable through this RPC.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000501', true);

SELECT throws_ok(
  $$SELECT public.update_and_publish_announcement(
    (SELECT id FROM public.event_announcements WHERE title = '新標題'),
    '再次編輯', '再次編輯'
  )$$,
  'announcement not found or immutable',
  'published announcements stay immutable'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
