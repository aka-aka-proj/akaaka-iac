BEGIN;

SELECT plan(12);

SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.event_announcements'::regclass),
  'announcement table keeps RLS enabled'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.event_announcements', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.event_announcements', 'INSERT')
    AND has_table_privilege('authenticated', 'public.event_announcements', 'SELECT'),
  'browser cannot write announcements directly but can read RLS-filtered rows'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.create_event_announcement(uuid,text,text,timestamptz,boolean)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.update_event_announcement(uuid,text,text,text,timestamptz)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.publish_event_announcement(uuid)', 'EXECUTE'),
  'authenticated owners receive only the constrained announcement RPCs'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.publish_due_event_announcements()', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.publish_due_event_announcements()', 'EXECUTE'),
  'scheduled publisher is not a browser API'
);

SELECT ok(
  (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = 'public.publish_event_announcement(uuid)'::regprocedure),
  'publish RPC is security definer'
);

SELECT ok(
  (SELECT p.proconfig @> ARRAY['search_path=public, extensions']
   FROM pg_proc p WHERE p.oid = 'public.publish_event_announcement(uuid)'::regprocedure),
  'publish RPC fixes its search path'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.event_announcements'::regclass
      AND conname = 'event_announcements_title_length'
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.event_announcements'::regclass
      AND conname = 'event_announcements_body_length'
  ),
  'announcement title and body length constraints exist'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.notifications'::regclass
      AND conname = 'notifications_notification_type_check'
      AND pg_get_constraintdef(oid) LIKE '%event_announcement%'
  ),
  'notifications accepts event_announcement type'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.notifications'::regclass
      AND conname = 'notifications_one_target'
      AND pg_get_constraintdef(oid) LIKE '%event_announcement_id%'
  ),
  'notification target constraint includes announcement id'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'notifications_event_announcement_target_unique'
  ),
  'announcement notification fan-out is idempotent per recipient'
);

SELECT ok(
  pg_get_functiondef('public.publish_event_announcement_internal(uuid,timestamptz)'::regprocedure)
    LIKE '%approved%'
    AND pg_get_functiondef('public.publish_event_announcement_internal(uuid,timestamptz)'::regprocedure)
      LIKE '%pending%'
    AND pg_get_functiondef('public.publish_event_announcement_internal(uuid,timestamptz)'::regprocedure)
      LIKE '%waitlisted%'
    AND pg_get_functiondef('public.publish_event_announcement_internal(uuid,timestamptz)'::regprocedure)
      LIKE '%cancelled%',
  'publish snapshot includes all four confirmed registration states'
);

SELECT ok(
  pg_get_functiondef('public.publish_event_announcement_internal(uuid,timestamptz)'::regprocedure)
    LIKE '%12 hours%'
    AND pg_get_functiondef('public.create_event_announcement(uuid,text,text,timestamptz,boolean)'::regprocedure)
      LIKE '%>= 5%',
  'publish frequency and per-event count limits are server-side'
);

SELECT * FROM finish();
ROLLBACK;
