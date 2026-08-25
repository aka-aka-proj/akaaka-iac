BEGIN;

SELECT plan(16);

-- Structural contracts -------------------------------------------------------

SELECT ok(
  (SELECT p.prosecdef
   FROM pg_proc p
   WHERE p.oid = 'public.update_and_publish_announcement(uuid,text,text)'::regprocedure),
  'atomic update-and-publish RPC is security definer'
);

SELECT ok(
  (SELECT p.proconfig @> ARRAY['search_path=public, extensions']
   FROM pg_proc p
   WHERE p.oid = 'public.update_and_publish_announcement(uuid,text,text)'::regprocedure),
  'atomic update-and-publish RPC fixes its search path'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.update_and_publish_announcement(uuid,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.update_and_publish_announcement(uuid,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.update_and_publish_announcement(uuid,text,text)', 'EXECUTE'),
  'only authenticated hosts may execute the atomic RPC'
);

-- Fixtures --------------------------------------------------------------------

INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
SELECT id, 'authenticated', 'authenticated', id::text || '@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()
FROM (
  VALUES
    ('00000000-0000-4000-8000-000000000601'::uuid),
    ('00000000-0000-4000-8000-000000000602'::uuid),
    ('00000000-0000-4000-8000-000000000603'::uuid)
) AS users(id);

INSERT INTO public.profiles (id, display_name, external_social_links)
SELECT id, 'Atomic ' || right(id::text, 3), '[{"url":"https://local.test"}]'::jsonb
FROM auth.users;

INSERT INTO public.events (
  id, creator_id, title, description, event_type, visibility_settings,
  start_time, lifecycle_status, publication_status
)
VALUES
  (
    '00000000-0000-4000-8000-000000000701',
    '00000000-0000-4000-8000-000000000601',
    'Atomic event one', 'fixture', 'other',
    '{"type":"private"}'::jsonb, now() + interval '1 day', 'published', 'published'
  ),
  (
    '00000000-0000-4000-8000-000000000702',
    '00000000-0000-4000-8000-000000000601',
    'Atomic event two', 'fixture', 'other',
    '{"type":"private"}'::jsonb, now() + interval '2 day', 'published', 'published'
  );

INSERT INTO public.event_registrations (event_id, profile_id, status)
VALUES
  ('00000000-0000-4000-8000-000000000701', '00000000-0000-4000-8000-000000000602', 'approved'),
  ('00000000-0000-4000-8000-000000000701', '00000000-0000-4000-8000-000000000603', 'pending'),
  ('00000000-0000-4000-8000-000000000702', '00000000-0000-4000-8000-000000000602', 'approved');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000601', true);

-- Happy path: edit a scheduled announcement and publish it atomically ----------

SELECT lives_ok(
  $$SELECT public.create_event_announcement(
    '00000000-0000-4000-8000-000000000701',
    'Original A', 'Body A',
    timezone('utc', now()) + interval '2 hours', FALSE
  )$$,
  'host creates scheduled announcement A'
);

SELECT id AS announcement_a
FROM public.event_announcements WHERE title = 'Original A'
\gset ato_

SELECT lives_ok(
  format(
    $$SELECT public.update_and_publish_announcement(%L::uuid, 'Edited A', 'Edited body A')$$,
    :'ato_announcement_a'
  ),
  'host can edit and immediately publish a scheduled announcement in one call'
);

SELECT is(
  (SELECT status = 'published'
     AND title = 'Edited A'
     AND body_markdown = 'Edited body A'
     AND publish_at IS NULL
     AND published_at IS NOT NULL
   FROM public.event_announcements WHERE id = :'ato_announcement_a'::uuid),
  TRUE,
  'the announcement lands in the published state carrying the edited content'
);

RESET ROLE;
SELECT is(
  (SELECT count(DISTINCT recipient_profile_id)::integer FROM public.notifications
   WHERE notification_type = 'event_announcement'
     AND event_announcement_id = :'ato_announcement_a'::uuid),
  2,
  'fan-out reaches every registrant exactly once'
);

-- Failure atomicity: the 12-hour limit must preserve schedule and content ------

SELECT public.create_event_announcement(
  '00000000-0000-4000-8000-000000000701',
  'Scheduled B', 'Body B',
  timezone('utc', now()) + interval '3 hours', FALSE
);
SELECT id AS announcement_b
FROM public.event_announcements WHERE title = 'Scheduled B'
\gset ato_

SELECT throws_ok(
  format(
    $$SELECT public.update_and_publish_announcement(%L::uuid, 'Edited B', 'Edited body B')$$,
    :'ato_announcement_b'
  ),
  'P1500',
  'event announcement frequency limit exceeded',
  'publishing a second announcement inside 12 hours is rejected'
);

SELECT is(
  (SELECT status = 'scheduled'
     AND title = 'Scheduled B'
     AND body_markdown = 'Body B'
     AND publish_at IS NOT NULL
     AND published_at IS NULL
   FROM public.event_announcements WHERE id = :'ato_announcement_b'::uuid),
  TRUE,
  'the failed call leaves schedule and content of B completely untouched'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000602', true);

SELECT throws_ok(
  format(
    $$SELECT public.update_and_publish_announcement(%L::uuid, 'Hijacked B', 'Hijacked body B')$$,
    :'ato_announcement_b'
  ),
  'P0001',
  'event not found or caller is not the host',
  'a non-host cannot edit or publish through the atomic RPC'
);

RESET ROLE;
SELECT is(
  (SELECT status = 'scheduled' AND title = 'Scheduled B'
   FROM public.event_announcements WHERE id = :'ato_announcement_b'::uuid),
  TRUE,
  'the rejected hijack attempt leaves B untouched'
);

-- Validation failure keeps the draft --------------------------------------------

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000601', true);
SELECT public.create_event_announcement(
  '00000000-0000-4000-8000-000000000701',
  'Draft D', 'Body D', NULL, FALSE
);
SELECT id AS announcement_d
FROM public.event_announcements WHERE title = 'Draft D'
\gset ato_

SELECT throws_ok(
  format(
    $$SELECT public.update_and_publish_announcement(%L::uuid, 'Edited D', 'link https://example.com is forbidden')$$,
    :'ato_announcement_d'
  ),
  'P0001',
  'announcement body is invalid',
  'markdown-safety violations abort the whole operation'
);

SELECT is(
  (SELECT status = 'draft' AND title = 'Draft D' AND body_markdown = 'Body D'
   FROM public.event_announcements WHERE id = :'ato_announcement_d'::uuid),
  TRUE,
  'a failed edit leaves the draft with its original content'
);

-- Draft path succeeds on an event without recent publications -------------------

SELECT public.create_event_announcement(
  '00000000-0000-4000-8000-000000000702',
  'Draft E', 'Body E', NULL, FALSE
);
SELECT id AS announcement_e
FROM public.event_announcements WHERE title = 'Draft E'
\gset ato_

SELECT lives_ok(
  format(
    $$SELECT public.update_and_publish_announcement(%L::uuid, 'Edited E', 'Edited body E')$$,
    :'ato_announcement_e'
  ),
  'a draft can be edited and published through the same atomic call'
);

SELECT is(
  (SELECT status = 'published' AND title = 'Edited E'
   FROM public.event_announcements WHERE id = :'ato_announcement_e'::uuid),
  TRUE,
  'the draft lands published with the edited title'
);

-- Published rows stay immutable --------------------------------------------------

SELECT throws_ok(
  format(
    $$SELECT public.update_and_publish_announcement(%L::uuid, 'Again A', 'Again body A')$$,
    :'ato_announcement_a'
  ),
  'P0001',
  'announcement not found or immutable',
  'an already published announcement cannot be edited or republished'
);

SELECT * FROM finish();
ROLLBACK;
