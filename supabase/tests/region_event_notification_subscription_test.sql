BEGIN;

SELECT plan(6);

SELECT has_column(
  'public', 'event_notification_subscriptions', 'location_region',
  'subscriptions expose location_region target'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.event_notification_subscriptions'::regclass
      AND conname = 'event_notification_subscriptions_exactly_one_target'
      AND pg_get_constraintdef(oid) LIKE '%num_nonnulls(event_type, creator_profile_id, location_region) = 1%'
  ),
  'subscription rows require exactly one target'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.event_notification_subscriptions'::regclass
      AND conname = 'event_notification_subscriptions_location_region_check'
      AND pg_get_constraintdef(oid) LIKE '%North%'
      AND pg_get_constraintdef(oid) LIKE '%Online%'
  ),
  'region target is restricted to canonical values'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'event_notification_subscriptions'
      AND indexname = 'event_notification_subscriptions_profile_region_uidx'
  ),
  'profile + region has a partial unique index'
);

SELECT ok(
  pg_get_functiondef('public.notify_subscribers_on_event_publication()'::regprocedure)
    LIKE '%s.location_region = NEW.location_region%',
  'publication fan-out matches region subscriptions'
);

SELECT ok(
  pg_get_functiondef('public.notify_subscribers_on_event_publication()'::regprocedure)
    LIKE '%SELECT DISTINCT s.profile_id%'
  AND pg_get_functiondef('public.notify_subscribers_on_event_publication()'::regprocedure)
    LIKE '%s.profile_id <> NEW.creator_id%'
  AND pg_get_functiondef('public.notify_subscribers_on_event_publication()'::regprocedure)
    LIKE '%FROM public.blocks%',
  'region fan-out retains dedupe, self exclusion, and block filtering'
);

SELECT * FROM finish();
ROLLBACK;
