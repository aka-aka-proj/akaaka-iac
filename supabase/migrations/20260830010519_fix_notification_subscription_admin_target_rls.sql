-- The creator existence check must use the privacy-safe public projection.
-- Direct reads from profiles are self-scoped for admins, so querying profiles
-- here incorrectly rejects an admin subscribing to another creator.
DROP POLICY IF EXISTS event_notification_subscriptions_insert_self
  ON public.event_notification_subscriptions;

CREATE POLICY event_notification_subscriptions_insert_self
  ON public.event_notification_subscriptions FOR INSERT TO authenticated
  WITH CHECK (
    (
      profile_id = auth.uid()
      AND creator_profile_id IS NULL
    ) OR (
      profile_id = auth.uid()
      AND creator_profile_id IS NOT NULL
      AND creator_profile_id <> auth.uid()
      AND EXISTS (
        SELECT 1
        FROM public.public_profiles p
        WHERE p.id = event_notification_subscriptions.creator_profile_id
      )
    )
  );
