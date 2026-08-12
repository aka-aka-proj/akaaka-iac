BEGIN;

SELECT plan(8);

SELECT is(
  to_regclass('public.connections')::text,
  NULL,
  'legacy connections table is retired'
);

SELECT is(
  (SELECT count(*)::int FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename = 'events'
     AND policyname IN ('events_read_all', 'Enable read access for all users')),
  0,
  'legacy all-events policies are absent'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'events'
      AND policyname = 'events_read_visibility'
      AND qual LIKE '%user_follows%'
  ),
  'event visibility uses user_follows'
);

SELECT ok(
  pg_get_functiondef('public.notify_subscribers_on_event_publication()'::regprocedure)
    LIKE '%user_follows%'
    AND pg_get_functiondef('public.notify_subscribers_on_event_publication()'::regprocedure)
    NOT LIKE '%public.connections%',
  'event notifications use mutual follows'
);

SELECT ok(
  pg_get_functiondef('public.create_direct_conversation(uuid)'::regprocedure)
    LIKE '%user_follows%',
  'direct conversation creation uses mutual follows'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'user_follows'
      AND policyname = 'user_follows_insert_self'
  ),
  'user_follows remains the browser relationship write surface'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'user_follows'
      AND policyname = 'user_follows_delete_self'
  ),
  'users can remove only their own follow rows'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('events', 'direct_conversations', 'direct_messages')
      AND (qual LIKE '%public.connections%' OR with_check LIKE '%public.connections%')
  ),
  'active relationship policies contain no legacy connections reference'
);

SELECT * FROM finish();
ROLLBACK;
