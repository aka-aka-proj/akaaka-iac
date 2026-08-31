BEGIN;

SELECT plan(8);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'event_notification_subscriptions'
      AND policyname = 'event_notification_subscriptions_insert_self'
      AND roles = '{authenticated}'
      AND cmd = 'INSERT'
      AND with_check LIKE '%public_profiles%'
      AND with_check NOT LIKE '%FROM profiles%'
  ),
  'subscription INSERT validates creator existence through public_profiles'
);

SELECT ok(
  has_table_privilege('authenticated', 'public.event_notification_subscriptions', 'INSERT'),
  'authenticated retains subscription INSERT privilege'
);

SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.event_notification_subscriptions'::regclass),
  'subscription table keeps RLS enabled'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'event_notification_subscriptions'
      AND policyname = 'event_notification_subscriptions_select_self'
      AND qual LIKE '%profile_id = auth.uid()%'
  ),
  'subscription SELECT remains owner-scoped'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'event_notification_subscriptions'
      AND policyname = 'event_notification_subscriptions_delete_self'
      AND qual LIKE '%profile_id = auth.uid()%'
  ),
  'subscription DELETE remains owner-scoped'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'event_notification_subscriptions'
      AND policyname = 'event_notification_subscriptions_insert_self'
      AND with_check LIKE '%creator_profile_id <> auth.uid()%'
  ),
  'creator self-subscription remains denied'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'event_notification_subscriptions'
      AND policyname = 'event_notification_subscriptions_insert_self'
      AND with_check LIKE '%profile_id = auth.uid()%'
  ),
  'subscription owner remains auth.uid-scoped'
);

SELECT ok(
  has_table_privilege('authenticated', 'public.public_profiles', 'SELECT'),
  'authenticated can resolve public creator profiles'
);

SELECT * FROM finish();
ROLLBACK;
