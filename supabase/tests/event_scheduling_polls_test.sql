BEGIN;
SELECT plan(22);

SET LOCAL session_replication_role = replica;
INSERT INTO auth.users (id,aud,role,email,raw_app_meta_data,raw_user_meta_data) VALUES
 ('18400000-0000-4000-8000-000000000001','authenticated','authenticated','poll-owner@test','{}','{}'),
 ('18400000-0000-4000-8000-000000000002','authenticated','authenticated','poll-voter@test','{}','{}'),
 ('18400000-0000-4000-8000-000000000003','authenticated','authenticated','poll-outsider@test','{}','{}'),
 ('18400000-0000-4000-8000-000000000004','authenticated','authenticated','poll-blocked@test','{}','{}');
INSERT INTO public.profiles (id,display_name,external_social_links) VALUES
 ('18400000-0000-4000-8000-000000000001','Owner','[]'),
 ('18400000-0000-4000-8000-000000000002','Voter','[]'),
 ('18400000-0000-4000-8000-000000000003','Outsider','[]'),
 ('18400000-0000-4000-8000-000000000004','Blocked','[]');
INSERT INTO public.events (id,creator_id,title,event_type,visibility_settings,start_time,lifecycle_status,publication_status,location_detail) VALUES
 ('18400000-0000-4000-8000-000000000011','18400000-0000-4000-8000-000000000001','Draft poll event','social','{"type":"public"}',now()+interval '30 days','draft','closed','Old place'),
 ('18400000-0000-4000-8000-000000000012','18400000-0000-4000-8000-000000000001','Second draft','social','{"type":"public"}',now()+interval '31 days','draft','closed','Old place');
SET LOCAL session_replication_role = origin;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.event_scheduling_polls, public.event_scheduling_poll_options, public.event_scheduling_poll_voters, public.event_scheduling_poll_votes TO authenticated;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"18400000-0000-4000-8000-000000000001","role":"authenticated"}',true);
SELECT lives_ok($$INSERT INTO public.event_scheduling_polls(id,event_id,creator_id) VALUES ('18400000-0000-4000-8000-000000000021','18400000-0000-4000-8000-000000000011','18400000-0000-4000-8000-000000000001')$$,'owner creates poll');
SELECT lives_ok($$INSERT INTO public.event_scheduling_poll_options(id,poll_id,kind,starts_at,sort_order) VALUES ('18400000-0000-4000-8000-000000000031','18400000-0000-4000-8000-000000000021','datetime',now()+interval '40 days',0),('18400000-0000-4000-8000-000000000032','18400000-0000-4000-8000-000000000021','datetime',now()+interval '41 days',1)$$,'owner adds dates');
SELECT lives_ok($$INSERT INTO public.event_scheduling_poll_options(id,poll_id,kind,location_label,sort_order) VALUES ('18400000-0000-4000-8000-000000000033','18400000-0000-4000-8000-000000000021','location','Taipei',2),('18400000-0000-4000-8000-000000000034','18400000-0000-4000-8000-000000000021','location','Taoyuan',3)$$,'owner adds locations');
SELECT lives_ok($$INSERT INTO public.event_scheduling_poll_voters(poll_id,profile_id) VALUES ('18400000-0000-4000-8000-000000000021','18400000-0000-4000-8000-000000000002')$$,'owner adds voter');
SELECT throws_ok($$INSERT INTO public.event_scheduling_polls(event_id,creator_id) VALUES ('18400000-0000-4000-8000-000000000012','18400000-0000-4000-8000-000000000003')$$,'23514',NULL,'owner cannot spoof creator');

SELECT set_config('request.jwt.claims','{"sub":"18400000-0000-4000-8000-000000000002","role":"authenticated"}',true);
SELECT is((SELECT count(*)::int FROM public.event_scheduling_polls WHERE id='18400000-0000-4000-8000-000000000021'),1,'eligible voter reads poll');
SELECT is((SELECT count(*)::int FROM public.event_scheduling_poll_options WHERE poll_id='18400000-0000-4000-8000-000000000021'),4,'eligible voter reads options');
SELECT lives_ok($$INSERT INTO public.event_scheduling_poll_votes(poll_id,option_id,profile_id) VALUES ('18400000-0000-4000-8000-000000000021','18400000-0000-4000-8000-000000000031','18400000-0000-4000-8000-000000000002') ON CONFLICT DO NOTHING$$,'vote is idempotent');
SELECT lives_ok($$INSERT INTO public.event_scheduling_poll_votes(poll_id,option_id,profile_id) VALUES ('18400000-0000-4000-8000-000000000021','18400000-0000-4000-8000-000000000031','18400000-0000-4000-8000-000000000002') ON CONFLICT DO NOTHING$$,'duplicate vote is no-op');
SELECT is((SELECT vote_count FROM public.get_event_scheduling_poll_results('18400000-0000-4000-8000-000000000021') WHERE option_id='18400000-0000-4000-8000-000000000031'),1::bigint,'aggregate count has no voter identity');

SELECT set_config('request.jwt.claims','{"sub":"18400000-0000-4000-8000-000000000003","role":"authenticated"}',true);
SELECT is((SELECT count(*)::int FROM public.event_scheduling_polls WHERE id='18400000-0000-4000-8000-000000000021'),0,'outsider cannot read poll');
SELECT throws_ok($$INSERT INTO public.event_scheduling_poll_votes(poll_id,option_id,profile_id) VALUES ('18400000-0000-4000-8000-000000000021','18400000-0000-4000-8000-000000000031','18400000-0000-4000-8000-000000000003')$$,'42501',NULL,'outsider is not an eligible voter');

RESET ROLE;
INSERT INTO public.event_scheduling_polls(id,event_id,creator_id) VALUES ('18400000-0000-4000-8000-000000000022','18400000-0000-4000-8000-000000000012','18400000-0000-4000-8000-000000000001');
INSERT INTO public.event_scheduling_poll_options(id,poll_id,kind,starts_at,sort_order) VALUES ('18400000-0000-4000-8000-000000000035','18400000-0000-4000-8000-000000000022','datetime',now()+interval '42 days',0);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"18400000-0000-4000-8000-000000000002","role":"authenticated"}',true);
SELECT throws_ok($$INSERT INTO public.event_scheduling_poll_votes(poll_id,option_id,profile_id) VALUES ('18400000-0000-4000-8000-000000000021','18400000-0000-4000-8000-000000000035','18400000-0000-4000-8000-000000000002')$$,'23503',NULL,'cross-poll option is rejected');

SELECT set_config('request.jwt.claims','{"sub":"18400000-0000-4000-8000-000000000001","role":"authenticated"}',true);
SELECT lives_ok($$DELETE FROM public.event_scheduling_poll_options WHERE id='18400000-0000-4000-8000-000000000031'$$,'owner can remove an option and invalidate existing votes');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.event_scheduling_poll_votes WHERE poll_id='18400000-0000-4000-8000-000000000021'),0,'removing an option clears all poll votes');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"18400000-0000-4000-8000-000000000001","role":"authenticated"}',true);
SELECT lives_ok($$SELECT public.finalize_event_scheduling_poll('18400000-0000-4000-8000-000000000021','18400000-0000-4000-8000-000000000032','18400000-0000-4000-8000-000000000034')$$,'owner finalizes atomically');
SELECT is((SELECT lifecycle_status FROM public.events WHERE id='18400000-0000-4000-8000-000000000011'),'draft','finalize does not publish');
SELECT is((SELECT location_detail FROM public.events WHERE id='18400000-0000-4000-8000-000000000011'),'Taoyuan','finalize applies location');
SELECT is((SELECT status FROM public.event_scheduling_polls WHERE id='18400000-0000-4000-8000-000000000021'),'closed','finalize closes poll');

SELECT set_config('request.jwt.claims','{"sub":"18400000-0000-4000-8000-000000000002","role":"authenticated"}',true);
SELECT throws_ok($$DELETE FROM public.event_scheduling_poll_votes WHERE poll_id='18400000-0000-4000-8000-000000000021' AND option_id='18400000-0000-4000-8000-000000000031' AND profile_id='18400000-0000-4000-8000-000000000002'$$,'P0001','poll is closed','closed poll is immutable');

RESET ROLE;
INSERT INTO public.blocks(blocker_id,blocked_id) VALUES ('18400000-0000-4000-8000-000000000001','18400000-0000-4000-8000-000000000004');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"18400000-0000-4000-8000-000000000001","role":"authenticated"}',true);
SELECT throws_ok($$INSERT INTO public.event_scheduling_poll_voters(poll_id,profile_id) VALUES ('18400000-0000-4000-8000-000000000022','18400000-0000-4000-8000-000000000004')$$,'42501',NULL,'blocked profile cannot be added');
RESET ROLE;
DELETE FROM public.events WHERE id='18400000-0000-4000-8000-000000000012';
SELECT is((SELECT count(*)::int FROM public.event_scheduling_polls WHERE id='18400000-0000-4000-8000-000000000022'),0,'event deletion cascades poll');

SELECT * FROM finish();
ROLLBACK;
