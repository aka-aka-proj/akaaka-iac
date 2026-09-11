BEGIN;

SELECT plan(6);

SET session_replication_role = replica;
INSERT INTO public.profiles (id) VALUES
  ('00000000-0000-4000-8000-000000001201'::uuid),
  ('00000000-0000-4000-8000-000000001202'::uuid);

INSERT INTO public.events (
  id, creator_id, title, start_time, location_region,
  lifecycle_status, publication_status, visibility_settings,
  event_type, attendance_fee_type
) VALUES (
  '00000000-0000-4000-8000-000000001210',
  '00000000-0000-4000-8000-000000001201',
  'Private share-token fixture',
  '2099-01-01T12:00:00Z',
  'Online',
  'published',
  'published',
  '{"type":"private"}'::jsonb,
  '{}',
  'free'
);
SET session_replication_role = origin;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000001201', true);

CREATE TEMP TABLE share_token_state AS
SELECT public.ensure_event_share_token('00000000-0000-4000-8000-000000001210') AS token;

SELECT ok(
  (SELECT token ~ '^[0-9a-f]{48}$' FROM share_token_state),
  'owner can mint a 192-bit token'
);

SELECT is(
  public.ensure_event_share_token('00000000-0000-4000-8000-000000001210'),
  (SELECT token FROM share_token_state),
  'ensure is idempotent'
);

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000001202', true);
SELECT is(
  public.ensure_event_share_token('00000000-0000-4000-8000-000000001210'),
  NULL::text,
  'non-owner cannot mint a token'
);

SELECT set_config('request.jwt.claim.sub', '', true);
SELECT is(
  (SELECT count(*)::bigint FROM public.get_event_by_share_token((SELECT token FROM share_token_state))),
  1::bigint,
  'valid token resolves the private event'
);

SELECT is(
  (SELECT count(*)::bigint FROM public.get_event_by_share_token(repeat('0', 48))),
  0::bigint,
  'invalid token returns no event'
);

SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000001201', true);
UPDATE public.events
SET publication_status = 'closed'
WHERE id = '00000000-0000-4000-8000-000000001210';

SELECT is(
  (SELECT count(*)::bigint FROM public.event_share_tokens
   WHERE event_id = '00000000-0000-4000-8000-000000001210'),
  0::bigint,
  'unpublishing deletes the bearer token'
);

SELECT * FROM finish();
ROLLBACK;
