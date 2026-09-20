BEGIN;
SELECT plan(14);

SET LOCAL session_replication_role = replica;
INSERT INTO auth.users (id,aud,role,email,raw_app_meta_data,raw_user_meta_data) VALUES
 ('18700000-0000-4000-8000-000000000001','authenticated','authenticated','reset-owner@test','{}','{}'),
 ('18700000-0000-4000-8000-000000000002','authenticated','authenticated','reset-voter@test','{}','{}'),
 ('18700000-0000-4000-8000-000000000003','authenticated','authenticated','reset-outsider@test','{}','{}');
INSERT INTO public.profiles (id,display_name,external_social_links) VALUES
 ('18700000-0000-4000-8000-000000000001','Owner','[]'),
 ('18700000-0000-4000-8000-000000000002','Voter','[]'),
 ('18700000-0000-4000-8000-000000000003','Outsider','[]');
INSERT INTO public.events (id,creator_id,title,event_type,visibility_settings,start_time,lifecycle_status,publication_status,location_detail) VALUES
 ('18700000-0000-4000-8000-000000000011','18700000-0000-4000-8000-000000000001','Reset poll event','social','{"type":"public"}',now()+interval '30 days','draft','closed','Old place');
SET LOCAL session_replication_role = origin;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"18700000-0000-4000-8000-000000000001","role":"authenticated"}',true);
INSERT INTO public.event_scheduling_polls(id,event_id,creator_id) VALUES ('18700000-0000-4000-8000-000000000021','18700000-0000-4000-8000-000000000011','18700000-0000-4000-8000-000000000001');
INSERT INTO public.event_scheduling_poll_options(id,poll_id,kind,starts_at,sort_order) VALUES
 ('18700000-0000-4000-8000-000000000031','18700000-0000-4000-8000-000000000021','datetime',now()+interval '40 days',0),
 ('18700000-0000-4000-8000-000000000032','18700000-0000-4000-8000-000000000021','datetime',now()+interval '41 days',1);
INSERT INTO public.event_scheduling_poll_voters(poll_id,profile_id) VALUES ('18700000-0000-4000-8000-000000000021','18700000-0000-4000-8000-000000000002');

SELECT set_config('request.jwt.claims','{"sub":"18700000-0000-4000-8000-000000000002","role":"authenticated"}',true);
INSERT INTO public.event_scheduling_poll_votes(poll_id,option_id,profile_id) VALUES ('18700000-0000-4000-8000-000000000021','18700000-0000-4000-8000-000000000031','18700000-0000-4000-8000-000000000002');
SELECT throws_ok($$SELECT public.reset_event_scheduling_poll_votes('18700000-0000-4000-8000-000000000021')$$,'42501',NULL,'eligible voter cannot reset votes');

SELECT set_config('request.jwt.claims','{"sub":"18700000-0000-4000-8000-000000000003","role":"authenticated"}',true);
SELECT throws_ok($$SELECT public.reset_event_scheduling_poll_votes('18700000-0000-4000-8000-000000000021')$$,'42501',NULL,'outsider cannot reset votes');

SELECT set_config('request.jwt.claims','{"sub":"18700000-0000-4000-8000-000000000001","role":"authenticated"}',true);
SELECT lives_ok($$SELECT public.reset_event_scheduling_poll_votes('18700000-0000-4000-8000-000000000021')$$,'owner resets votes');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.event_scheduling_poll_votes WHERE poll_id='18700000-0000-4000-8000-000000000021'),0,'manual reset clears all votes independent of vote RLS');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"18700000-0000-4000-8000-000000000001","role":"authenticated"}',true);
SELECT is((SELECT count(*)::int FROM public.event_scheduling_poll_options WHERE poll_id='18700000-0000-4000-8000-000000000021'),2,'manual reset preserves options');
SELECT is((SELECT count(*)::int FROM public.event_scheduling_poll_voters WHERE poll_id='18700000-0000-4000-8000-000000000021'),1,'manual reset preserves voters');
SELECT is((SELECT status FROM public.event_scheduling_polls WHERE id='18700000-0000-4000-8000-000000000021'),'open','manual reset keeps poll open');
SELECT lives_ok($$SELECT public.reset_event_scheduling_poll_votes('18700000-0000-4000-8000-000000000021')$$,'reset is idempotent when already empty');

SELECT set_config('request.jwt.claims','{"sub":"18700000-0000-4000-8000-000000000002","role":"authenticated"}',true);
SELECT lives_ok($$INSERT INTO public.event_scheduling_poll_votes(poll_id,option_id,profile_id) VALUES ('18700000-0000-4000-8000-000000000021','18700000-0000-4000-8000-000000000032','18700000-0000-4000-8000-000000000002')$$,'eligible voter can vote again after reset');
SELECT is((SELECT count(*)::int FROM public.event_scheduling_poll_votes WHERE poll_id='18700000-0000-4000-8000-000000000021'),1,'re-vote is stored after reset');

-- Poll voting-configuration changes invalidate every existing vote atomically.
SELECT set_config('request.jwt.claims','{"sub":"18700000-0000-4000-8000-000000000001","role":"authenticated"}',true);
SELECT lives_ok($$UPDATE public.event_scheduling_poll_options SET sort_order=5 WHERE id='18700000-0000-4000-8000-000000000032'$$,'owner can alter an open poll option');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.event_scheduling_poll_votes WHERE poll_id='18700000-0000-4000-8000-000000000021'),0,'altering a poll option clears all existing votes');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"18700000-0000-4000-8000-000000000002","role":"authenticated"}',true);
INSERT INTO public.event_scheduling_poll_votes(poll_id,option_id,profile_id) VALUES ('18700000-0000-4000-8000-000000000021','18700000-0000-4000-8000-000000000031','18700000-0000-4000-8000-000000000002');
SELECT is((SELECT count(*)::int FROM public.event_scheduling_poll_votes WHERE poll_id='18700000-0000-4000-8000-000000000021'),1,'fresh vote exists before voter-set alteration');

SELECT set_config('request.jwt.claims','{"sub":"18700000-0000-4000-8000-000000000001","role":"authenticated"}',true);
INSERT INTO public.event_scheduling_poll_voters(poll_id,profile_id) VALUES ('18700000-0000-4000-8000-000000000021','18700000-0000-4000-8000-000000000003');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.event_scheduling_poll_votes WHERE poll_id='18700000-0000-4000-8000-000000000021'),0,'altering eligible voters clears all existing votes');

SELECT * FROM finish();
ROLLBACK;
