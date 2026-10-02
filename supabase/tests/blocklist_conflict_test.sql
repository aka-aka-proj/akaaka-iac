BEGIN;
SELECT no_plan();

SET session_replication_role = replica;
INSERT INTO auth.users (id,aud,role,email,raw_app_meta_data,raw_user_meta_data)
SELECT ('19100000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,
 'authenticated','authenticated','blocklist-' || n || '@local.test','{}','{}'
FROM generate_series(1,5) n;
INSERT INTO public.profiles (id,display_name,external_social_links)
SELECT id,'Blocklist fixture','[]' FROM auth.users WHERE id::text LIKE '19100000-%';
INSERT INTO public.events (id,creator_id,title,event_type,visibility_settings,start_time,publication_status,lifecycle_status)
SELECT ('19100000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,
 '19100000-0000-4000-8000-000000000001','Blocklist test','social','{"type":"public"}',now()+interval '1 day','published','published'
FROM generate_series(11,14) n;
INSERT INTO public.event_registrations (event_id,profile_id,status)
SELECT id,'19100000-0000-4000-8000-000000000003','approved' FROM public.events WHERE id::text LIKE '19100000-%';
UPDATE public.event_registrations SET status='cancelled' WHERE event_id='19100000-0000-4000-8000-000000000013';
INSERT INTO public.blocks (blocker_id,blocked_id) VALUES
 ('19100000-0000-4000-8000-000000000002','19100000-0000-4000-8000-000000000003');
INSERT INTO public.event_series (id,creator_id,title,lifecycle_status) VALUES
 ('19100000-0000-4000-8000-000000000021','19100000-0000-4000-8000-000000000001','Blocklist series','published');
INSERT INTO public.event_series_membership (series_id,event_id,position) VALUES
 ('19100000-0000-4000-8000-000000000021','19100000-0000-4000-8000-000000000013',1),
 ('19100000-0000-4000-8000-000000000021','19100000-0000-4000-8000-000000000014',2);
SET session_replication_role = origin;

SELECT throws_ok($$SELECT * FROM public.create_event_registration_atomic('19100000-0000-4000-8000-000000000011','19100000-0000-4000-8000-000000000002')$$,
 'P0001','blocklist_confirmation_required','old single RPC cannot bypass outgoing conflict');
SELECT is((SELECT count(*)::int FROM public.event_registrations WHERE profile_id='19100000-0000-4000-8000-000000000002'),0,'warning creates no registration');
SELECT throws_ok($$SELECT * FROM public.create_event_registration_checked('19100000-0000-4000-8000-000000000011','19100000-0000-4000-8000-000000000002',false)$$,
 'P0001','blocklist_confirmation_required','unchecked request requires confirmation');
SELECT lives_ok($$SELECT * FROM public.create_event_registration_checked('19100000-0000-4000-8000-000000000011','19100000-0000-4000-8000-000000000002',true)$$,
 'explicit acknowledgment allows pending registration');
SELECT is((SELECT status FROM public.event_registrations WHERE event_id='19100000-0000-4000-8000-000000000011' AND profile_id='19100000-0000-4000-8000-000000000002'),'pending','acknowledgment does not auto approve');
SELECT throws_ok($$SELECT * FROM public.create_event_registration_checked('19100000-0000-4000-8000-000000000012','19100000-0000-4000-8000-000000000002',false)$$,
 'P0001','blocklist_confirmation_required','acknowledgment does not carry to another event');
SELECT throws_ok($$UPDATE public.event_registrations SET status='approved' WHERE event_id='19100000-0000-4000-8000-000000000011' AND profile_id='19100000-0000-4000-8000-000000000002'$$,
 'P0001','blocklist_confirmation_required','direct approval needs its own consent');
SELECT throws_ok($$SELECT * FROM public.review_event_registration_checked('19100000-0000-4000-8000-000000000011',(SELECT id FROM public.event_registrations WHERE event_id='19100000-0000-4000-8000-000000000011' AND profile_id='19100000-0000-4000-8000-000000000002'),'19100000-0000-4000-8000-000000000004','approve',true)$$,
 'P0001','forbidden','acknowledgment cannot bypass host ownership');
SELECT lives_ok($$SELECT * FROM public.review_event_registration_checked('19100000-0000-4000-8000-000000000011',(SELECT id FROM public.event_registrations WHERE event_id='19100000-0000-4000-8000-000000000011' AND profile_id='19100000-0000-4000-8000-000000000002'),'19100000-0000-4000-8000-000000000001','approve',true)$$,
 'host explicit consent approves');

-- Reverse-only block is never disclosed to the applicant, but warns the host.
INSERT INTO public.blocks (blocker_id,blocked_id) VALUES
 ('19100000-0000-4000-8000-000000000003','19100000-0000-4000-8000-000000000004');
SELECT lives_ok($$SELECT * FROM public.create_event_registration_checked('19100000-0000-4000-8000-000000000012','19100000-0000-4000-8000-000000000004',false)$$,
 'reverse-only block does not warn applicant');
SELECT throws_ok($$SELECT * FROM public.review_event_registration_checked('19100000-0000-4000-8000-000000000012',(SELECT id FROM public.event_registrations WHERE event_id='19100000-0000-4000-8000-000000000012' AND profile_id='19100000-0000-4000-8000-000000000004'),'19100000-0000-4000-8000-000000000001','approve',false)$$,
 'P0001','blocklist_confirmation_required','reverse-only block warns host');
SELECT lives_ok($$SELECT * FROM public.review_event_registration_checked('19100000-0000-4000-8000-000000000012',(SELECT id FROM public.event_registrations WHERE event_id='19100000-0000-4000-8000-000000000012' AND profile_id='19100000-0000-4000-8000-000000000004'),'19100000-0000-4000-8000-000000000001','reject',false)$$,
 'rejection does not require consent');
SELECT throws_ok($$UPDATE public.event_registrations SET status='approved' WHERE event_id='19100000-0000-4000-8000-000000000012' AND profile_id='19100000-0000-4000-8000-000000000004'$$,
 'P0001','invalid_status_transition','direct writes cannot reactivate a rejected registration to bypass review');

SELECT throws_ok($$SELECT * FROM public.register_event_series_checked('19100000-0000-4000-8000-000000000021','19100000-0000-4000-8000-000000000002','{}',ARRAY['19100000-0000-4000-8000-000000000013','19100000-0000-4000-8000-000000000014']::uuid[],false)$$,
 'P0001','blocklist_confirmation_required','series warning is transactional');
SELECT is((SELECT count(*)::int FROM public.event_series_registrations WHERE series_id='19100000-0000-4000-8000-000000000021'),0,'series warning leaves no parent row');
SELECT is((SELECT count(*)::int FROM public.event_registrations WHERE profile_id='19100000-0000-4000-8000-000000000002' AND event_id IN ('19100000-0000-4000-8000-000000000013','19100000-0000-4000-8000-000000000014')),0,'later series conflict rolls back earlier child insert');
SELECT lives_ok($$SELECT * FROM public.register_event_series_checked('19100000-0000-4000-8000-000000000021','19100000-0000-4000-8000-000000000002','{}',ARRAY['19100000-0000-4000-8000-000000000013','19100000-0000-4000-8000-000000000014']::uuid[],true)$$,
 'series consent covers the submitted membership snapshot');
SELECT is((SELECT count(*)::int FROM public.event_registrations WHERE profile_id='19100000-0000-4000-8000-000000000002' AND event_id IN ('19100000-0000-4000-8000-000000000013','19100000-0000-4000-8000-000000000014') AND status='approved'),2,'series retains automatic approval');

INSERT INTO public.blocks (blocker_id,blocked_id) VALUES
 ('19100000-0000-4000-8000-000000000001','19100000-0000-4000-8000-000000000005');
SELECT throws_ok($$SELECT * FROM public.create_event_registration_checked('19100000-0000-4000-8000-000000000011','19100000-0000-4000-8000-000000000005',true)$$,
 'P0001','registration_blocked','consent cannot override host block');
SELECT results_eq($$SELECT count(*)::int FROM private.registration_blocklist_acknowledgements$$,ARRAY[0],'consent receipts do not persist');
SELECT ok(NOT has_table_privilege('authenticated','private.registration_blocklist_acknowledgements','INSERT'),'browser cannot forge consent');
SELECT ok(NOT has_function_privilege('authenticated','public.create_event_registration_checked(uuid,uuid,boolean)','EXECUTE'),'checked RPC not callable by browser');
SELECT ok(has_function_privilege('service_role','public.create_event_registration_checked(uuid,uuid,boolean)','EXECUTE'),'Edge Function may call checked RPC');

-- Every documented status is checked independently.
SET session_replication_role = replica;
UPDATE public.event_registrations SET status='pending' WHERE event_id='19100000-0000-4000-8000-000000000012' AND profile_id='19100000-0000-4000-8000-000000000003';
SET session_replication_role = origin;
SELECT throws_ok($$SELECT * FROM public.create_event_registration_checked('19100000-0000-4000-8000-000000000012','19100000-0000-4000-8000-000000000002',false)$$,'P0001','blocklist_confirmation_required','warns about pending peer');
SET session_replication_role = replica;
UPDATE public.event_registrations SET status='approved' WHERE event_id='19100000-0000-4000-8000-000000000012' AND profile_id='19100000-0000-4000-8000-000000000003';
SET session_replication_role = origin;
SELECT throws_ok($$SELECT * FROM public.create_event_registration_checked('19100000-0000-4000-8000-000000000012','19100000-0000-4000-8000-000000000002',false)$$,'P0001','blocklist_confirmation_required','warns about approved peer');
SET session_replication_role = replica;
UPDATE public.event_registrations SET status='waitlisted' WHERE event_id='19100000-0000-4000-8000-000000000012' AND profile_id='19100000-0000-4000-8000-000000000003';
SET session_replication_role = origin;
SELECT throws_ok($$SELECT * FROM public.create_event_registration_checked('19100000-0000-4000-8000-000000000012','19100000-0000-4000-8000-000000000002',false)$$,'P0001','blocklist_confirmation_required','warns about waitlisted peer');
SET session_replication_role = replica;
UPDATE public.event_registrations SET status='cancellation_pending' WHERE event_id='19100000-0000-4000-8000-000000000012' AND profile_id='19100000-0000-4000-8000-000000000003';
SET session_replication_role = origin;
SELECT throws_ok($$SELECT * FROM public.create_event_registration_checked('19100000-0000-4000-8000-000000000012','19100000-0000-4000-8000-000000000002',false)$$,'P0001','blocklist_confirmation_required','warns about cancellation_pending peer');
SET session_replication_role = replica;
UPDATE public.event_registrations SET status='cancellation_rejected' WHERE event_id='19100000-0000-4000-8000-000000000012' AND profile_id='19100000-0000-4000-8000-000000000003';
SET session_replication_role = origin;
SELECT throws_ok($$SELECT * FROM public.create_event_registration_checked('19100000-0000-4000-8000-000000000012','19100000-0000-4000-8000-000000000002',false)$$,'P0001','blocklist_confirmation_required','warns about cancellation_rejected peer');
SET session_replication_role = replica;
UPDATE public.event_registrations SET status='rejected' WHERE event_id='19100000-0000-4000-8000-000000000012' AND profile_id='19100000-0000-4000-8000-000000000003';
SET session_replication_role = origin;
SELECT lives_ok($$SELECT * FROM public.create_event_registration_checked('19100000-0000-4000-8000-000000000012','19100000-0000-4000-8000-000000000002',false)$$,'ignores rejected peer');
DELETE FROM public.event_registrations WHERE event_id='19100000-0000-4000-8000-000000000012' AND profile_id='19100000-0000-4000-8000-000000000002';
SET session_replication_role = replica;
UPDATE public.event_registrations SET status='cancelled' WHERE event_id='19100000-0000-4000-8000-000000000012' AND profile_id='19100000-0000-4000-8000-000000000003';
SET session_replication_role = origin;
SELECT lives_ok($$SELECT * FROM public.create_event_registration_checked('19100000-0000-4000-8000-000000000012','19100000-0000-4000-8000-000000000002',false)$$,'ignores cancelled peer');
DELETE FROM public.event_registrations WHERE event_id='19100000-0000-4000-8000-000000000012' AND profile_id='19100000-0000-4000-8000-000000000002';
SELECT throws_ok($$SELECT * FROM public.register_event_series_checked('19100000-0000-4000-8000-000000000021','19100000-0000-4000-8000-000000000004','{}',ARRAY['19100000-0000-4000-8000-000000000014']::uuid[],true)$$,
 'P0001','series membership changed; please retry','consent cannot approve a changed series snapshot');
SELECT lives_ok($$SELECT * FROM public.create_event_registration_checked('19100000-0000-4000-8000-000000000011','19100000-0000-4000-8000-000000000004',false)$$,'prepare capacity review');
UPDATE public.events SET max_capacity=1 WHERE id='19100000-0000-4000-8000-000000000011';
SELECT throws_ok($$SELECT * FROM public.review_event_registration_checked('19100000-0000-4000-8000-000000000011',(SELECT id FROM public.event_registrations WHERE event_id='19100000-0000-4000-8000-000000000011' AND profile_id='19100000-0000-4000-8000-000000000004'),'19100000-0000-4000-8000-000000000001','approve',true)$$,
 'P0001','capacity_reached','consent cannot bypass approval capacity');
SELECT throws_ok($$SELECT * FROM public.review_event_registration_checked('19100000-0000-4000-8000-000000000012',(SELECT id FROM public.event_registrations WHERE event_id='19100000-0000-4000-8000-000000000011' AND profile_id='19100000-0000-4000-8000-000000000004'),'19100000-0000-4000-8000-000000000001','approve',true)$$,
 'P0001','not_found','registration must belong to the selected event');
SELECT results_eq($$SELECT count(*)::int FROM private.registration_blocklist_acknowledgements$$,ARRAY[0],'failed confirmed writes also leave no receipts');
SELECT ok(NOT has_table_privilege('service_role','private.registration_blocklist_acknowledgements','INSERT'),'service client cannot forge receipt table writes');
SELECT ok(NOT has_function_privilege('authenticated','public.review_event_registration_checked(uuid,uuid,uuid,text,boolean)','EXECUTE'),'browser cannot impersonate host through review RPC');
SELECT ok(NOT has_function_privilege('authenticated','public.register_event_series_checked(uuid,uuid,jsonb,uuid[],boolean)','EXECUTE'),'browser cannot impersonate series applicant');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','19100000-0000-4000-8000-000000000002',true);
SELECT is((SELECT count(*)::int FROM public.blocks),1,'management list only reads caller outgoing blocks');
WITH removed AS (DELETE FROM public.blocks WHERE blocker_id='19100000-0000-4000-8000-000000000003' RETURNING 1) SELECT is((SELECT count(*)::int FROM removed),0,'management cannot unblock for another user');
RESET ROLE;
UPDATE public.events SET visibility_settings='{"type":"private"}' WHERE id='19100000-0000-4000-8000-000000000012';
SET session_replication_role = replica;
UPDATE public.event_registrations SET status='approved' WHERE event_id='19100000-0000-4000-8000-000000000012' AND profile_id='19100000-0000-4000-8000-000000000003';
SET session_replication_role = origin;
SET LOCAL ROLE authenticated;
SELECT throws_ok($$INSERT INTO public.event_registrations(event_id,profile_id,status) VALUES ('19100000-0000-4000-8000-000000000012','19100000-0000-4000-8000-000000000002','pending')$$,
 'P0001','forbidden','inaccessible event cannot disclose peer conflicts through direct insert');
RESET ROLE;
UPDATE public.events SET visibility_settings=$json${"type":"public"}$json$ WHERE id=$id$19100000-0000-4000-8000-000000000012$id$;
SET LOCAL ROLE authenticated;
SELECT throws_ok($$INSERT INTO public.event_registrations(event_id,profile_id,status) VALUES ($id$19100000-0000-4000-8000-000000000012$id$,$id$19100000-0000-4000-8000-000000000002$id$,$s$pending$s$)$$,
 $s$P0001$s$,$s$forbidden$s$,$s$direct registration must use the eligibility-checked endpoint$s$);
SELECT throws_ok($$INSERT INTO public.event_registrations(event_id,profile_id,status) VALUES ($id$19100000-0000-4000-8000-000000000012$id$,$id$19100000-0000-4000-8000-000000000005$id$,$s$pending$s$)$$,
 $s$P0001$s$,$s$forbidden$s$,$s$another profile cannot be used to probe conflict information$s$);
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
