BEGIN;

SELECT plan(8);

SET session_replication_role = replica;
INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
VALUES
  ('00000000-0000-4000-8000-000000000701', 'authenticated', 'authenticated', 'profile-viewer@local.test', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('00000000-0000-4000-8000-000000000702', 'authenticated', 'authenticated', 'profile-target@local.test', '{}'::jsonb, '{}'::jsonb, now(), now());
INSERT INTO public.profiles (id, display_name, external_social_links)
VALUES
  ('00000000-0000-4000-8000-000000000701', 'Viewer', '[]'::jsonb),
  ('00000000-0000-4000-8000-000000000702', 'Target', '[{"platform":"x","url":"https://x.com/target"},{"platform":"instagram","url":"https://instagram.com/target"}]'::jsonb);
SET session_replication_role = origin;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000701', true);

SELECT is(
  (SELECT x_link_provided FROM public.get_profile_for_viewer('00000000-0000-4000-8000-000000000702')),
  true,
  'non-mutual viewer can learn that an X link exists'
);
SELECT is(
  (SELECT jsonb_path_exists(external_social_links, '$[*] ? (@.platform == "x")') FROM public.get_profile_for_viewer('00000000-0000-4000-8000-000000000702')),
  false,
  'non-mutual viewer cannot receive the X URL'
);

SET session_replication_role = replica;
INSERT INTO public.user_follows (follower_id, followed_id)
VALUES
  ('00000000-0000-4000-8000-000000000701', '00000000-0000-4000-8000-000000000702'),
  ('00000000-0000-4000-8000-000000000702', '00000000-0000-4000-8000-000000000701');
SET session_replication_role = origin;

SELECT is(
  (SELECT external_social_links -> 0 ->> 'url' FROM public.get_profile_for_viewer('00000000-0000-4000-8000-000000000702')),
  'https://x.com/target',
  'mutually-followed viewer receives the X URL'
);

SET session_replication_role = replica;
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('00000000-0000-4000-8000-000000000702', '00000000-0000-4000-8000-000000000701');
SET session_replication_role = origin;

SELECT is(
  (SELECT jsonb_path_exists(external_social_links, '$[*] ? (@.platform == "x")') FROM public.get_profile_for_viewer('00000000-0000-4000-8000-000000000702')),
  false,
  'a block removes X URL access even when follows remain'
);
SELECT is(
  (SELECT x_link_provided FROM public.get_profile_for_viewer('00000000-0000-4000-8000-000000000702')),
  true,
  'blocked viewer still receives only the X-link availability signal'
);

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000702', true);
SELECT is(
  (SELECT external_social_links -> 0 ->> 'url' FROM public.get_profile_for_viewer('00000000-0000-4000-8000-000000000702')),
  'https://x.com/target',
  'profile owner receives their own X URL'
);
SELECT ok(
  has_function_privilege('anon', 'public.get_profile_for_viewer(uuid)', 'EXECUTE') = false,
  'anonymous callers cannot execute the resolver'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.get_profile_for_viewer(uuid)', 'EXECUTE'),
  'authenticated callers can execute the resolver'
);

SELECT * FROM finish();
ROLLBACK;
