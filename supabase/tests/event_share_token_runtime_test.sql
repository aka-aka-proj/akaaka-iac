BEGIN;

-- Local role/claims behavior, not proof of hosted JWT validation or product sign-off.
-- Contract: sharing spec 7; RLS matrix share-token RPC boundary (issue #102).
SELECT no_plan();

SET session_replication_role = replica;
INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
SELECT ('10200000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  'authenticated', 'authenticated', 'share-token-' || n || '@local.test', '{}', '{}'
FROM generate_series(1, 2) n;
INSERT INTO public.profiles (id, display_name, external_social_links)
SELECT id, 'Share-token fixture', '[]' FROM auth.users WHERE id::text LIKE '10200000-%';
INSERT INTO public.events (id, creator_id, title, event_type, start_time,
  lifecycle_status, publication_status, visibility_settings)
SELECT ('10200000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  '10200000-0000-4000-8000-000000000001', 'Share-token fixture', 'social', now() + interval '7 days',
  CASE WHEN n = 15 THEN 'draft' ELSE 'published' END,
  'published', '{"type":"private"}'::jsonb
FROM generate_series(11, 16) n;
SET session_replication_role = origin;

-- Test-only storage permits token comparisons across SET ROLE without granting
-- any access to the real bearer-credential table.
CREATE TEMP TABLE share_token_state (event_id uuid PRIMARY KEY, original_token text, rotated_token text);
INSERT INTO share_token_state (event_id) SELECT id FROM public.events WHERE id::text LIKE '10200000-%';
GRANT SELECT, UPDATE ON share_token_state TO authenticated, anon;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000001', true);
UPDATE share_token_state SET original_token = public.ensure_event_share_token(event_id) WHERE event_id <> '10200000-0000-4000-8000-000000000015';
SELECT ok((SELECT bool_and(COALESCE(original_token ~ '^[0-9a-f]{48}$', false)) FROM share_token_state WHERE event_id <> '10200000-0000-4000-8000-000000000015'), 'owner mints 192-bit private published tokens');
SELECT is(public.ensure_event_share_token('10200000-0000-4000-8000-000000000011'), (SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'), 'owner ensure is idempotent');
SELECT is(public.ensure_event_share_token('10200000-0000-4000-8000-000000000015'), NULL::text, 'owner cannot ensure a draft token');
SELECT is(public.rotate_event_share_token('10200000-0000-4000-8000-000000000015'), NULL::text, 'owner cannot rotate a draft token');

SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000002', true);
SELECT is(public.ensure_event_share_token('10200000-0000-4000-8000-000000000011'), NULL::text, 'non-owner cannot retrieve or mint owner token');
SELECT is(public.rotate_event_share_token('10200000-0000-4000-8000-000000000011'), NULL::text, 'non-owner cannot rotate owner token');
SELECT results_eq($$SELECT id FROM public.get_event_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'))$$, $$VALUES ('10200000-0000-4000-8000-000000000011'::uuid)$$, 'authenticated token holder resolves the matching event');
SELECT results_eq($$SELECT * FROM public.get_event_capacity_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'))$$, $$VALUES (0::bigint, 0::bigint)$$, 'authenticated token holder receives capacity aggregates');

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.event_share_tokens$$, '42501', NULL, 'authenticated cannot directly read bearer credentials');
SELECT throws_ok($$INSERT INTO public.event_share_tokens (event_id, token) VALUES ('10200000-0000-4000-8000-000000000011', repeat('a', 48))$$, '42501', NULL, 'authenticated cannot directly insert bearer credentials');
SELECT throws_ok($$UPDATE public.event_share_tokens SET token = repeat('b', 48)$$, '42501', NULL, 'authenticated cannot directly update bearer credentials');
SELECT throws_ok($$DELETE FROM public.event_share_tokens$$, '42501', NULL, 'authenticated cannot directly delete bearer credentials');
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token(repeat('0', 48))), 0, 'authenticated get_event_by_share_token hides invalid token');
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token(NULL::text)), 0, 'authenticated get_event_by_share_token hides NULL token');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token(repeat('0', 48))), 0, 'authenticated get_event_capacity_by_share_token hides invalid token');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token(NULL::text)), 0, 'authenticated get_event_capacity_by_share_token hides NULL token');

RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT throws_ok($$SELECT * FROM public.event_share_tokens$$, '42501', NULL, 'anon cannot directly read bearer credentials');
SELECT throws_ok($$INSERT INTO public.event_share_tokens (event_id, token) VALUES ('10200000-0000-4000-8000-000000000011', repeat('a', 48))$$, '42501', NULL, 'anon cannot directly insert bearer credentials');
SELECT throws_ok($$UPDATE public.event_share_tokens SET token = repeat('b', 48)$$, '42501', NULL, 'anon cannot directly update bearer credentials');
SELECT throws_ok($$DELETE FROM public.event_share_tokens$$, '42501', NULL, 'anon cannot directly delete bearer credentials');
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token(repeat('0', 48))), 0, 'anon get_event_by_share_token hides invalid token');
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token(NULL::text)), 0, 'anon get_event_by_share_token hides NULL token');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token(repeat('0', 48))), 0, 'anon get_event_capacity_by_share_token hides invalid token');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token(NULL::text)), 0, 'anon get_event_capacity_by_share_token hides NULL token');
SELECT throws_ok($$SELECT public.ensure_event_share_token('10200000-0000-4000-8000-000000000011')$$, '42501', NULL, 'anon cannot execute ensure');
SELECT throws_ok($$SELECT public.rotate_event_share_token('10200000-0000-4000-8000-000000000011')$$, '42501', NULL, 'anon cannot execute rotate');
SELECT results_eq($$SELECT id FROM public.get_event_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'))$$, $$VALUES ('10200000-0000-4000-8000-000000000011'::uuid)$$, 'anon valid token resolves event');
SELECT results_eq($$SELECT * FROM public.get_event_capacity_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'))$$, $$VALUES (0::bigint, 0::bigint)$$, 'anon valid token resolves capacity');

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000001', true);
SELECT is(public.ensure_event_share_token('10200000-0000-4000-8000-000000000011'), (SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'), 'denied attempts leave owner token unchanged');
UPDATE share_token_state SET rotated_token = public.rotate_event_share_token(event_id) WHERE event_id = '10200000-0000-4000-8000-000000000011';
SELECT ok((SELECT rotated_token ~ '^[0-9a-f]{48}$' AND rotated_token <> original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'), 'rotation produces a different valid token');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'))), 0, 'get_event_by_share_token rotation original_token visibility');
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token((SELECT rotated_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'))), 1, 'get_event_by_share_token rotation rotated_token visibility');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'))), 0, 'get_event_capacity_by_share_token rotation original_token visibility');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token((SELECT rotated_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'))), 1, 'get_event_capacity_by_share_token rotation rotated_token visibility');

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000002', true);
INSERT INTO public.blocks (blocker_id, blocked_id) VALUES ('10200000-0000-4000-8000-000000000002', '10200000-0000-4000-8000-000000000001');
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000002', true);
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token((SELECT rotated_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'))), 0, 'viewer blocks creator: get_event_by_share_token denies token access');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token((SELECT rotated_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'))), 0, 'viewer blocks creator: get_event_capacity_by_share_token denies token access');
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000002', true);
DELETE FROM public.blocks WHERE blocker_id = auth.uid();

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000001', true);
INSERT INTO public.blocks (blocker_id, blocked_id) VALUES ('10200000-0000-4000-8000-000000000001', '10200000-0000-4000-8000-000000000002');
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000002', true);
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token((SELECT rotated_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'))), 0, 'creator blocks viewer: get_event_by_share_token denies token access');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token((SELECT rotated_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000011'))), 0, 'creator blocks viewer: get_event_capacity_by_share_token denies token access');
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000001', true);
DELETE FROM public.blocks WHERE blocker_id = auth.uid();
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000001', true);
SELECT throws_ok($$UPDATE public.events SET lifecycle_status = 'draft' WHERE id = '10200000-0000-4000-8000-000000000011'$$, 'P0001', 'published events cannot return to draft', 'owner cannot use a draft roundtrip to bypass lifecycle guards');

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000001', true);
SELECT lives_ok($$UPDATE public.events SET visibility_settings = '{"type":"public"}'::jsonb WHERE id = '10200000-0000-4000-8000-000000000012'$$, 'owner public transition succeeds with normal authorization');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.event_share_tokens WHERE event_id = '10200000-0000-4000-8000-000000000012'), 0, 'public transition removes bearer credential');
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000012'))), 0, 'public: get_event_by_share_token invalidates old token');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000012'))), 0, 'public: get_event_capacity_by_share_token invalidates old token');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000001', true);
SELECT is(public.ensure_event_share_token('10200000-0000-4000-8000-000000000012'), NULL::text, 'public event refuses ensure_event_share_token');
SELECT is(public.rotate_event_share_token('10200000-0000-4000-8000-000000000012'), NULL::text, 'public event refuses rotate_event_share_token');
SELECT lives_ok($$UPDATE public.events SET visibility_settings = '{"type":"private"}'::jsonb WHERE id = '10200000-0000-4000-8000-000000000012'$$, 'owner restores public event to shareable state');
UPDATE share_token_state SET rotated_token = public.ensure_event_share_token(event_id) WHERE event_id = '10200000-0000-4000-8000-000000000012';
SELECT ok((SELECT rotated_token ~ '^[0-9a-f]{48}$' AND rotated_token <> original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000012'), 'restoring public event creates a new token');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000012'))), 0, 'restored public: get_event_by_share_token original_token visibility');
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token((SELECT rotated_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000012'))), 1, 'restored public: get_event_by_share_token rotated_token visibility');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000012'))), 0, 'restored public: get_event_capacity_by_share_token original_token visibility');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token((SELECT rotated_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000012'))), 1, 'restored public: get_event_capacity_by_share_token rotated_token visibility');

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000001', true);
SELECT lives_ok($$UPDATE public.events SET visibility_settings = '{"type":"connections_only"}'::jsonb WHERE id = '10200000-0000-4000-8000-000000000013'$$, 'owner connections_only transition succeeds with normal authorization');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.event_share_tokens WHERE event_id = '10200000-0000-4000-8000-000000000013'), 0, 'connections_only transition removes bearer credential');
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000013'))), 0, 'connections_only: get_event_by_share_token invalidates old token');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000013'))), 0, 'connections_only: get_event_capacity_by_share_token invalidates old token');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000001', true);
SELECT is(public.ensure_event_share_token('10200000-0000-4000-8000-000000000013'), NULL::text, 'connections_only event refuses ensure_event_share_token');
SELECT is(public.rotate_event_share_token('10200000-0000-4000-8000-000000000013'), NULL::text, 'connections_only event refuses rotate_event_share_token');
SELECT lives_ok($$UPDATE public.events SET visibility_settings = '{"type":"private"}'::jsonb WHERE id = '10200000-0000-4000-8000-000000000013'$$, 'owner restores connections_only event to shareable state');
UPDATE share_token_state SET rotated_token = public.ensure_event_share_token(event_id) WHERE event_id = '10200000-0000-4000-8000-000000000013';
SELECT ok((SELECT rotated_token ~ '^[0-9a-f]{48}$' AND rotated_token <> original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000013'), 'restoring connections_only event creates a new token');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000013'))), 0, 'restored connections_only: get_event_by_share_token original_token visibility');
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token((SELECT rotated_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000013'))), 1, 'restored connections_only: get_event_by_share_token rotated_token visibility');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000013'))), 0, 'restored connections_only: get_event_capacity_by_share_token original_token visibility');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token((SELECT rotated_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000013'))), 1, 'restored connections_only: get_event_capacity_by_share_token rotated_token visibility');

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000001', true);
SELECT lives_ok($$SELECT public.set_event_publication('10200000-0000-4000-8000-000000000014', 'closed', NULL, NULL)$$, 'owner closed transition succeeds with normal authorization');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.event_share_tokens WHERE event_id = '10200000-0000-4000-8000-000000000014'), 0, 'closed transition removes bearer credential');
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000014'))), 0, 'closed: get_event_by_share_token invalidates old token');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000014'))), 0, 'closed: get_event_capacity_by_share_token invalidates old token');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000001', true);
SELECT is(public.ensure_event_share_token('10200000-0000-4000-8000-000000000014'), NULL::text, 'closed event refuses ensure_event_share_token');
SELECT is(public.rotate_event_share_token('10200000-0000-4000-8000-000000000014'), NULL::text, 'closed event refuses rotate_event_share_token');
SELECT lives_ok($$SELECT public.set_event_publication('10200000-0000-4000-8000-000000000014', 'published', NULL, NULL)$$, 'owner restores closed event to shareable state');
UPDATE share_token_state SET rotated_token = public.ensure_event_share_token(event_id) WHERE event_id = '10200000-0000-4000-8000-000000000014';
SELECT ok((SELECT rotated_token ~ '^[0-9a-f]{48}$' AND rotated_token <> original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000014'), 'restoring closed event creates a new token');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000014'))), 0, 'restored closed: get_event_by_share_token original_token visibility');
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token((SELECT rotated_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000014'))), 1, 'restored closed: get_event_by_share_token rotated_token visibility');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000014'))), 0, 'restored closed: get_event_capacity_by_share_token original_token visibility');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token((SELECT rotated_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000014'))), 1, 'restored closed: get_event_capacity_by_share_token rotated_token visibility');

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10200000-0000-4000-8000-000000000001', true);
SELECT lives_ok($$DELETE FROM public.events WHERE id = '10200000-0000-4000-8000-000000000016'$$, 'owner deleted transition succeeds with normal authorization');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.event_share_tokens WHERE event_id = '10200000-0000-4000-8000-000000000016'), 0, 'deleted transition removes bearer credential');
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000016'))), 0, 'deleted: get_event_by_share_token invalidates old token');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token((SELECT original_token FROM share_token_state WHERE event_id = '10200000-0000-4000-8000-000000000016'))), 0, 'deleted: get_event_capacity_by_share_token invalidates old token');

-- A stale draft credential is fixture corruption, not an allowed owner transition.
-- Keep all triggers enabled while exercising the draft hygiene branch.
RESET ROLE;
INSERT INTO public.event_share_tokens (event_id, token) VALUES ('10200000-0000-4000-8000-000000000015', repeat('d', 48));
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT is((SELECT count(*)::int FROM public.get_event_by_share_token(repeat('d', 48))), 0, 'draft resolver gate rejects even a stale credential');
SELECT is((SELECT count(*)::int FROM public.get_event_capacity_by_share_token(repeat('d', 48))), 0, 'draft capacity gate rejects even a stale credential');
RESET ROLE;
UPDATE public.events SET lifecycle_status = 'draft' WHERE id = '10200000-0000-4000-8000-000000000015';
SELECT is((SELECT count(*)::int FROM public.event_share_tokens WHERE event_id = '10200000-0000-4000-8000-000000000015'), 0, 'draft hygiene deletes stale credential with triggers enabled');

SELECT * FROM finish();
ROLLBACK;
