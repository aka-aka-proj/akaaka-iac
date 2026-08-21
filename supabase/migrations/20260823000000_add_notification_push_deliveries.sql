-- Transactional outbox for Web Push delivery. This migration never calls a
-- provider; it only records delivery work created with the notification.
CREATE TABLE IF NOT EXISTS public.notification_push_deliveries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  notification_id UUID NOT NULL REFERENCES public.notifications(id) ON DELETE CASCADE,
  -- Deliberately not a foreign key: endpoint cleanup must preserve delivery
  -- audit/idempotency metadata after the owner deletes the subscription.
  push_subscription_id UUID NOT NULL,
  idempotency_key TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'sent', 'endpoint_invalid', 'dead_letter')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  available_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  claimed_at TIMESTAMPTZ,
  sent_at TIMESTAMPTZ,
  last_error_code TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (notification_id, push_subscription_id)
);

CREATE INDEX IF NOT EXISTS idx_notification_push_deliveries_claim
  ON public.notification_push_deliveries (status, available_at, created_at);

ALTER TABLE public.notification_push_deliveries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.notification_push_deliveries FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.notification_push_deliveries TO service_role;

CREATE OR REPLACE FUNCTION public.enqueue_notification_push_deliveries()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  INSERT INTO public.notification_push_deliveries (
    notification_id,
    push_subscription_id,
    idempotency_key
  )
  SELECT
    NEW.id,
    ps.id,
    md5(NEW.id::text || ':' || ps.id::text)
  FROM public.push_subscriptions ps
  WHERE ps.profile_id = NEW.recipient_profile_id
  ON CONFLICT (notification_id, push_subscription_id) DO NOTHING;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_notification_push_deliveries() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_enqueue_notification_push_deliveries ON public.notifications;
CREATE TRIGGER trg_enqueue_notification_push_deliveries
AFTER INSERT ON public.notifications
FOR EACH ROW
EXECUTE FUNCTION public.enqueue_notification_push_deliveries();

CREATE OR REPLACE FUNCTION public.claim_notification_push_deliveries(
  p_limit INTEGER DEFAULT 25,
  p_now TIMESTAMPTZ DEFAULT timezone('utc', now())
)
RETURNS TABLE (
  delivery_id UUID,
  notification_id UUID,
  push_subscription_id UUID,
  idempotency_key TEXT,
  attempts INTEGER,
  notification_type TEXT,
  event_id UUID,
  actor_profile_id UUID,
  venue_application_profile_id UUID,
  endpoint TEXT,
  p256dh TEXT,
  auth TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'invalid_delivery_limit';
  END IF;

  UPDATE public.notification_push_deliveries d
  SET status = 'endpoint_invalid',
      last_error_code = 'subscription_missing',
      updated_at = p_now
  WHERE d.status IN ('pending', 'processing')
    AND NOT EXISTS (
      SELECT 1
      FROM public.push_subscriptions ps
      WHERE ps.id = d.push_subscription_id
    );

  RETURN QUERY
  WITH candidates AS (
    SELECT d.id
    FROM public.notification_push_deliveries d
    JOIN public.push_subscriptions ps ON ps.id = d.push_subscription_id
    WHERE (
      d.status = 'pending'
      AND d.available_at <= p_now
    ) OR (
      d.status = 'processing'
      AND d.claimed_at < p_now - interval '5 minutes'
    )
    ORDER BY d.available_at, d.created_at, d.id
    LIMIT p_limit
    FOR UPDATE OF d SKIP LOCKED
  ), claimed AS (
    UPDATE public.notification_push_deliveries d
    SET status = 'processing',
        attempts = d.attempts + 1,
        claimed_at = p_now,
        updated_at = p_now
    FROM candidates c
    WHERE d.id = c.id
    RETURNING d.*
  )
  SELECT
    c.id,
    c.notification_id,
    c.push_subscription_id,
    c.idempotency_key,
    c.attempts,
    n.notification_type,
    n.event_id,
    n.actor_profile_id,
    n.venue_application_profile_id,
    ps.endpoint,
    ps.p256dh,
    ps.auth
  FROM claimed c
  JOIN public.notifications n ON n.id = c.notification_id
  JOIN public.push_subscriptions ps ON ps.id = c.push_subscription_id;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_notification_push_deliveries(INTEGER, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_notification_push_deliveries(INTEGER, TIMESTAMPTZ) TO service_role;
