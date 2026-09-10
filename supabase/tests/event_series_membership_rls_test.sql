BEGIN;
SELECT plan(14);

-- Seed only fixtures as database owner; exercise every mutation with RLS enabled.
SET LOCAL session_replication_role = replica;
INSERT INTO auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
VALUES
 ('b1170000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'membership-owner@local.test', '{}', '{}'),
 ('b1170000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'membership-other@local.test', '{}', '{}');
INSERT INTO public.profiles (id, display_name, external_social_links)
VALUES
 ('b1170000-0000-4000-8000-000000000001', 'Membership owner', '[]'),
 ('b1170000-0000-4000-8000-000000000002', 'Other owner', '[]');
INSERT INTO public.event_series (id, creator_id, title, lifecycle_status)
VALUES
 ('b1170000-0000-4000-8000-000000000011', 'b1170000-0000-4000-8000-000000000001', 'Owner draft A', 'draft'),
 ('b1170000-0000-4000-8000-000000000012', 'b1170000-0000-4000-8000-000000000001', 'Owner draft B', 'draft'),
 ('b1170000-0000-4000-8000-000000000013', 'b1170000-0000-4000-8000-000000000002', 'Other draft', 'draft'),
 ('b1170000-0000-4000-8000-000000000014', 'b1170000-0000-4000-8000-000000000001', 'Owner published', 'published');
INSERT INTO public.events (id, creator_id, title, event_type, visibility_settings, start_time, lifecycle_status, publication_status)
VALUES
 ('b1170000-0000-4000-8000-000000000021', 'b1170000-0000-4000-8000-000000000001', 'Owner draft event', 'social', '{"type":"public"}', now()+interval '30 days', 'draft', 'closed'),
 ('b1170000-0000-4000-8000-000000000022', 'b1170000-0000-4000-8000-000000000001', 'Owner replacement event', 'social', '{"type":"public"}', now()+interval '30 days', 'draft', 'closed'),
 ('b1170000-0000-4000-8000-000000000023', 'b1170000-0000-4000-8000-000000000002', 'Other draft event', 'social', '{"type":"public"}', now()+interval '30 days', 'draft', 'closed'),
 ('b1170000-0000-4000-8000-000000000024', 'b1170000-0000-4000-8000-000000000001', 'Owner published event', 'social', '{"type":"public"}', now()+interval '30 days', 'published', 'published');
INSERT INTO public.event_series_membership (id, series_id, event_id, position)
VALUES ('b1170000-0000-4000-8000-000000000031', 'b1170000-0000-4000-8000-000000000011', 'b1170000-0000-4000-8000-000000000022', 1);
SET LOCAL session_replication_role = origin;
-- Isolate RLS from environment-dependent default table grants. Rolled back below.
GRANT INSERT, UPDATE ON public.event_series_membership TO authenticated;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"b1170000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}', true);

SELECT lives_ok($$INSERT INTO public.event_series_membership (series_id,event_id,position) VALUES ('b1170000-0000-4000-8000-000000000011','b1170000-0000-4000-8000-000000000021',2)$$,
 'owner can add own draft event without a recurring series_id');
SELECT is((SELECT count(*)::int FROM public.event_series_membership WHERE event_id='b1170000-0000-4000-8000-000000000021'),1,'owner insert persisted');
SELECT lives_ok($$UPDATE public.event_series_membership SET position=3 WHERE id='b1170000-0000-4000-8000-000000000031'$$,'owner can reorder own draft membership');
SELECT is((SELECT position FROM public.event_series_membership WHERE id='b1170000-0000-4000-8000-000000000031'),3,'owner position update persisted');
SELECT lives_ok($$UPDATE public.event_series_membership SET series_id='b1170000-0000-4000-8000-000000000012' WHERE id='b1170000-0000-4000-8000-000000000031'$$,'owner can move membership to another owned draft series');
SELECT is((SELECT series_id FROM public.event_series_membership WHERE id='b1170000-0000-4000-8000-000000000031'),'b1170000-0000-4000-8000-000000000012'::uuid,'owner series update persisted');
SELECT throws_ok($$INSERT INTO public.event_series_membership (series_id,event_id,position) VALUES ('b1170000-0000-4000-8000-000000000011','b1170000-0000-4000-8000-000000000023',4)$$,'42501',NULL,'owner cannot add another users event');
SELECT throws_ok($$UPDATE public.event_series_membership SET series_id='b1170000-0000-4000-8000-000000000013' WHERE id='b1170000-0000-4000-8000-000000000031'$$,'42501',NULL,'owner cannot move membership to another users series');
SELECT throws_ok($$UPDATE public.event_series_membership SET event_id='b1170000-0000-4000-8000-000000000023' WHERE id='b1170000-0000-4000-8000-000000000031'$$,'42501',NULL,'owner cannot replace membership with another users event');
SELECT throws_ok($$INSERT INTO public.event_series_membership (series_id,event_id,position) VALUES ('b1170000-0000-4000-8000-000000000011','b1170000-0000-4000-8000-000000000024',4)$$,'42501',NULL,'published events cannot be added');
SELECT throws_ok($$UPDATE public.event_series_membership SET series_id='b1170000-0000-4000-8000-000000000014' WHERE id='b1170000-0000-4000-8000-000000000031'$$,'42501',NULL,'published target series rejects membership');
SELECT set_config('request.jwt.claims', '{"sub":"b1170000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal1"}', true);
SELECT throws_ok($$INSERT INTO public.event_series_membership (series_id,event_id,position) VALUES ('b1170000-0000-4000-8000-000000000011','b1170000-0000-4000-8000-000000000023',5)$$,'42501',NULL,'another user cannot insert into owners series');
WITH changed AS (UPDATE public.event_series_membership SET position=8 WHERE id='b1170000-0000-4000-8000-000000000031' RETURNING id) SELECT is((SELECT count(*)::int FROM changed),0,'another user cannot update owners membership');
RESET ROLE;
SELECT is((SELECT position FROM public.event_series_membership WHERE id='b1170000-0000-4000-8000-000000000031'),3,'denied updates leave original membership unchanged');
SELECT * FROM finish();
ROLLBACK;
