-- Issue #62: push subscription endpoint uniqueness and lifecycle cleanup.
-- EXPAND-ONLY phase of the rollout defined in
-- docs/spec/api/004-web-push-subscription-hygiene.md §Rollout ordering:
-- this migration must NOT add the global endpoint unique constraint or the
-- not-blank CHECKs. Those are tightening changes reserved for a separate
-- contract-step migration that ships only after the consuming frontend
-- release evidence exists. Legacy clients keep working unchanged.
-- Contracts: akaaka-docs docs/spec/api/004-web-push-subscription-hygiene.md,
-- docs/spec/database/001-akaaka-supabase-schema.md, ADR-021.

-- 1) Widen the delivery status vocabulary with the terminal `cancelled`
-- state: the target subscription was removed by scheduled cleanup or its
-- endpoint moved to another profile, so the delivery must never be sent.
ALTER TABLE public.notification_push_deliveries
  DROP CONSTRAINT IF EXISTS notification_push_deliveries_status_check;
ALTER TABLE public.notification_push_deliveries ADD CONSTRAINT notification_push_deliveries_status_check
  CHECK (status IN ('pending', 'processing', 'sent', 'endpoint_invalid', 'cancelled', 'dead_letter'));

-- 2) Preflight historical blank rows before any tightening step can land
-- later: the legacy schema only had NOT NULL, so empty strings may exist and
-- they can never deliver anything. Delete them up front (expand phase keeps
-- data repair separate from constraint enforcement).
DELETE FROM public.push_subscriptions
WHERE length(trim(endpoint)) = 0
   OR length(trim(p256dh)) = 0
   OR length(trim(auth)) = 0;

-- 3) Dedupe historical rows. Keep exactly one row per endpoint: the newest
-- by updated_at, with a deterministic tie-breaker for rows written in the
-- same statement. Deliveries pointing at discarded rows have no foreign key
-- by design and are preserved as audit history; the claim path terminalizes
-- them as `cancelled`.
DELETE FROM public.push_subscriptions a
USING public.push_subscriptions b
WHERE a.endpoint = b.endpoint
  AND (b.updated_at, b.created_at, b.id) > (a.updated_at, a.created_at, a.id);

-- 4) Supporting index for the cleanup liveness predicate: server-side
-- recency of successful delivery per subscription.
CREATE INDEX IF NOT EXISTS idx_notification_push_deliveries_subscription_sent
  ON public.notification_push_deliveries (push_subscription_id, sent_at)
  WHERE sent_at IS NOT NULL;

-- 5) Controlled subscription write path. Cross-profile ownership transfer is
-- only possible through this SECURITY DEFINER function and requires
-- possession proof: the supplied p256dh/auth must match the stored row
-- exactly, because endpoint URLs alone are not secret. Moving an endpoint
-- quarantines every outstanding delivery fanned out for the previous owner
-- in the same transaction, so a worker can never deliver account A's
-- notification to an endpoint now controlled by account B.
CREATE OR REPLACE FUNCTION public.subscribe_push_subscription(
  p_endpoint TEXT,
  p_p256dh TEXT,
  p_auth TEXT,
  p_user_agent TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_profile_id UUID;
  v_subscription_id UUID;
  v_existing RECORD;
BEGIN
  v_profile_id := auth.uid();
  IF v_profile_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF p_endpoint IS NULL OR length(trim(p_endpoint)) = 0
     OR p_p256dh IS NULL OR length(trim(p_p256dh)) = 0
     OR p_auth IS NULL OR length(trim(p_auth)) = 0 THEN
    RAISE EXCEPTION 'invalid_subscription_payload';
  END IF;

  SELECT id, profile_id, p256dh, auth
    INTO v_existing
    FROM public.push_subscriptions
   WHERE endpoint = trim(p_endpoint)
   FOR UPDATE;

  -- Fresh endpoint (or same-profile race on a brand-new endpoint): plain
  -- insert; the composite conflict target only fires for this profile.
  IF v_existing.id IS NULL THEN
    INSERT INTO public.push_subscriptions AS ps (
      profile_id,
      endpoint,
      p256dh,
      auth,
      user_agent
    )
    VALUES (
      v_profile_id,
      trim(p_endpoint),
      trim(p_p256dh),
      trim(p_auth),
      p_user_agent
    )
    ON CONFLICT (profile_id, endpoint) DO UPDATE
    SET p256dh = EXCLUDED.p256dh,
        auth = EXCLUDED.auth,
        user_agent = EXCLUDED.user_agent,
        updated_at = timezone('utc', now())
    RETURNING ps.id INTO v_subscription_id;
    RETURN v_subscription_id;
  END IF;

  -- Same owner re-subscribing (session refresh, key rotation): update in
  -- place and keep the row fresh against the cleanup threshold.
  IF v_existing.profile_id = v_profile_id THEN
    UPDATE public.push_subscriptions
       SET p256dh = trim(p_p256dh),
           auth = trim(p_auth),
           user_agent = p_user_agent,
           updated_at = timezone('utc', now())
     WHERE id = v_existing.id
     RETURNING id INTO v_subscription_id;
    RETURN v_subscription_id;
  END IF;

  -- Cross-profile transfer demands possession proof: key material only
  -- exists inside the real browser subscription, so "knowing the endpoint"
  -- must never be enough to take it over.
  IF trim(p_p256dh) <> v_existing.p256dh
     OR trim(p_auth) <> v_existing.auth THEN
    RAISE EXCEPTION 'endpoint_conflict';
  END IF;

  UPDATE public.push_subscriptions
     SET profile_id = v_profile_id,
         user_agent = p_user_agent,
         updated_at = timezone('utc', now())
   WHERE id = v_existing.id
   RETURNING id INTO v_subscription_id;

  -- Quarantine outstanding deliveries of the previous owner inside the same
  -- transaction. Already-terminal rows stay untouched as audit history.
  UPDATE public.notification_push_deliveries
     SET status = 'cancelled',
         last_error_code = 'endpoint_moved',
         updated_at = timezone('utc', now())
   WHERE push_subscription_id = v_existing.id
     AND status IN ('pending', 'processing');

  RETURN v_subscription_id;
END;
$$;

REVOKE ALL ON FUNCTION public.subscribe_push_subscription(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.subscribe_push_subscription(TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- 5b) Client write-path tightening: browser clients subscribe exclusively
-- through the controlled RPC above; direct INSERT/UPDATE would bypass the
-- possession-proof and move-quarantine semantics. Self-service unsubscribe
-- stays a plain RLS-scoped DELETE. Service-side workers keep full access.
REVOKE INSERT, UPDATE ON public.push_subscriptions FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.push_subscriptions TO service_role;
GRANT SELECT ON public.notifications TO service_role;

-- 6) Scheduled hygiene: delete subscriptions that are stale on BOTH the
-- client-driven clock (`updated_at`) and the server-observed one (most
-- recent successful delivery). A subscription that still receives
-- notifications survives even if the client never re-visits the app. Pure
-- database-side cleanup; provider revocation (404/410) stays with the
-- delivery fan-out worker. Bounded input prevents a misconfigured scheduler
-- from wiping active subscriptions.
CREATE OR REPLACE FUNCTION public.cleanup_stale_push_subscriptions(
  p_stale_days INTEGER DEFAULT 90
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_deleted INTEGER;
  v_cutoff TIMESTAMPTZ;
BEGIN
  IF p_stale_days IS NULL OR p_stale_days < 30 OR p_stale_days > 730 THEN
    RAISE EXCEPTION 'invalid_stale_days';
  END IF;

  v_cutoff := timezone('utc', now()) - (p_stale_days * interval '1 day');

  WITH deleted AS (
    DELETE FROM public.push_subscriptions ps
    WHERE ps.updated_at < v_cutoff
      AND NOT EXISTS (
        SELECT 1
        FROM public.notification_push_deliveries d
        WHERE d.push_subscription_id = ps.id
          AND d.sent_at IS NOT NULL
          AND d.sent_at >= v_cutoff
      )
    RETURNING 1
  )
  SELECT count(*)::INTEGER
    INTO v_deleted
    FROM deleted;

  RETURN COALESCE(v_deleted, 0);
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_stale_push_subscriptions(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cleanup_stale_push_subscriptions(INTEGER) TO service_role;

-- 7) Claim-path guard (api/003): before any claim candidate is selected,
-- terminalize work that must never be delivered — the target subscription
-- was removed by scheduled cleanup (`subscription_missing`), or the
-- endpoint's ownership moved to another profile (`endpoint_moved`). Doing
-- this centrally keeps the worker free of cross-table ownership checks and
-- makes the transition atomic with claim serialization.
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
     SET status = 'cancelled',
         last_error_code = CASE
           WHEN EXISTS (
             SELECT 1 FROM public.push_subscriptions ps
              WHERE ps.id = d.push_subscription_id
           ) THEN 'endpoint_moved'
           ELSE 'subscription_missing'
         END,
         updated_at = p_now
   WHERE d.status IN ('pending', 'processing')
     AND (
       NOT EXISTS (
         SELECT 1
         FROM public.push_subscriptions ps
         WHERE ps.id = d.push_subscription_id
       )
       OR EXISTS (
         SELECT 1
         FROM public.push_subscriptions ps
         JOIN public.notifications n ON n.id = d.notification_id
         WHERE ps.id = d.push_subscription_id
           AND n.recipient_profile_id <> ps.profile_id
       )
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
