-- Web Push subscription metadata. Delivery is performed later by a controlled worker.
CREATE TABLE IF NOT EXISTS public.push_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  endpoint TEXT NOT NULL,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT push_subscriptions_endpoint_not_blank CHECK (length(trim(endpoint)) > 0),
  CONSTRAINT push_subscriptions_p256dh_not_blank CHECK (length(trim(p256dh)) > 0),
  CONSTRAINT push_subscriptions_auth_not_blank CHECK (length(trim(auth)) > 0),
  UNIQUE (profile_id, endpoint)
);

CREATE INDEX IF NOT EXISTS idx_push_subscriptions_profile_id
  ON public.push_subscriptions (profile_id);

ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS push_subscriptions_select_self ON public.push_subscriptions;
CREATE POLICY push_subscriptions_select_self
  ON public.push_subscriptions FOR SELECT TO authenticated
  USING (profile_id = (select auth.uid()));

DROP POLICY IF EXISTS push_subscriptions_insert_self ON public.push_subscriptions;
CREATE POLICY push_subscriptions_insert_self
  ON public.push_subscriptions FOR INSERT TO authenticated
  WITH CHECK (profile_id = (select auth.uid()));

DROP POLICY IF EXISTS push_subscriptions_update_self ON public.push_subscriptions;
CREATE POLICY push_subscriptions_update_self
  ON public.push_subscriptions FOR UPDATE TO authenticated
  USING (profile_id = (select auth.uid()))
  WITH CHECK (profile_id = (select auth.uid()));

DROP POLICY IF EXISTS push_subscriptions_delete_self ON public.push_subscriptions;
CREATE POLICY push_subscriptions_delete_self
  ON public.push_subscriptions FOR DELETE TO authenticated
  USING (profile_id = (select auth.uid()));
