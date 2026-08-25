-- Ownership generation fencing + lease-fenced write-backs for Web Push
-- delivery (api/003 §Delivery and concurrency, api/004 §Idempotency and
-- concurrency; contract text landed in akaaka-docs PR #126).
--
-- Expand-only: this migration adds a column, appends claim output fields,
-- extends the subscribe RPC with an optional mode parameter and introduces a
-- service-side settle RPC. It removes no privilege and adds no tightening
-- constraint; legacy clients keep working unchanged.

BEGIN;

-- 1) Ownership generation: bumped on every cross-profile handover of a
-- subscription. The delivery worker compares the value returned at claim
-- time with a fresh read just before sending (and at write-back) so that an
-- endpoint moved to another profile mid-flight can never receive the
-- previous profile's notification.
ALTER TABLE public.push_subscriptions
  ADD COLUMN IF NOT EXISTS owner_generation INTEGER NOT NULL DEFAULT 0;

-- 2) Subscribe RPC gains p_mode (api/004 §Request):
--   standard (default): full contract — create unowned endpoints, refresh own
--     rows in place, move other-owned rows on possession proof.
--   refresh: session-start refresh only — create unowned / refresh own;
--     other-owned rows are never moved and the call returns NULL so the
--     passive caller silently skips instead of acquiring someone else's
--     subscription.
CREATE OR REPLACE FUNCTION public.subscribe_push_subscription(
  p_endpoint TEXT,
  p_p256dh TEXT,
  p_auth TEXT,
  p_user_agent TEXT DEFAULT NULL,
  p_mode TEXT DEFAULT 'standard'
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

  IF p_mode IS NULL OR p_mode NOT IN ('standard', 'refresh') THEN
    RAISE EXCEPTION 'invalid_subscription_payload';
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
  -- Both modes allow creation so a session-start refresh can re-adopt an
  -- endpoint removed by cleanup or revocation while the user is away.
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

  IF v_existing.profile_id = v_profile_id THEN
    -- Same owner re-subscribing (session refresh, key rotation): update in
    -- place and keep the row fresh against the cleanup threshold. Ownership
    -- did not change, so owner_generation stays put.
    UPDATE public.push_subscriptions
       SET p256dh = trim(p_p256dh),
           auth = trim(p_auth),
           user_agent = p_user_agent,
           updated_at = timezone('utc', now())
     WHERE id = v_existing.id
     RETURNING id INTO v_subscription_id;
    RETURN v_subscription_id;
  END IF;

  -- The row belongs to another profile. Refresh mode is a passive call: it
  -- must never acquire someone else's subscription, so it reports not-owned
  -- as NULL and leaves the row untouched.
  IF p_mode = 'refresh' THEN
    RETURN NULL;
  END IF;

  -- Cross-profile transfer demands possession proof: key material only
  -- exists inside the real browser subscription, so "knowing the endpoint"
  -- must never be enough to take it over.
  IF trim(p_p256dh) <> v_existing.p256dh
     OR trim(p_auth) <> v_existing.auth THEN
    RAISE EXCEPTION 'endpoint_conflict';
  END IF;

  -- Possession proven. Defer the move while an active send is in flight:
  -- a worker holding an unexpired processing lease is mid "owner check ->
  -- provider send", and racing the ownership change here would let that
  -- send land new-owner keys onto old-owner work. Deferral makes move and
  -- send mutually exclusive at the lease boundary; clients retry naturally.
  IF EXISTS (
    SELECT 1
      FROM public.notification_push_deliveries d
     WHERE d.push_subscription_id = v_existing.id
       AND d.status = 'processing'
       AND d.claimed_at >= timezone('utc', now()) - interval '5 minutes'
  ) THEN
    RAISE EXCEPTION 'endpoint_move_deferred';
  END IF;

  -- Bump the ownership generation in the same transaction as the move: any
  -- worker still holding pre-move claim state loses its fencing on the next
  -- generation comparison.
  UPDATE public.push_subscriptions
     SET profile_id = v_profile_id,
         user_agent = p_user_agent,
         owner_generation = owner_generation + 1,
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

REVOKE ALL ON FUNCTION public.subscribe_push_subscription(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.subscribe_push_subscription(TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- The pre-p_mode four-argument identity is superseded by the extended
-- definition above: its optional arguments let existing three- and
-- four-argument calls resolve unchanged. PostgreSQL cannot widen a function
-- in place (OUT row type changes and parameter additions are both rejected
-- by CREATE OR REPLACE), so the legacy identity is dropped within this same
-- transaction; PostgREST clients calling by name are unaffected.
DROP FUNCTION IF EXISTS public.subscribe_push_subscription(TEXT, TEXT, TEXT, TEXT);

-- 3) Claim response returns the lease identity (claimed_at + incremented
-- attempts per api/003 §Delivery and concurrency) plus the subscription's
-- current owner_generation so the worker can fence sends and write-backs on
-- both lease theft and mid-flight ownership moves.
--
-- PostgreSQL forbids changing a function's OUT-parameter row type in place,
-- so the extended response ships as an overload: the legacy two-argument
-- form stays exactly as deployed (unupgraded workers keep working across
-- the migration window), while the delivery worker opts into the extended
-- context by passing the explicit third argument.
CREATE OR REPLACE FUNCTION public.claim_notification_push_deliveries(
  -- All three arguments deliberately lack defaults: a defaulted argument
  -- cannot precede a required one (SQLSTATE 42P13), and optional arguments
  -- would make every existing two-argument call resolve ambiguously against
  -- this overload.
  p_limit INTEGER,
  p_now TIMESTAMPTZ,
  p_return_lease_context BOOLEAN
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
  auth TEXT,
  claimed_at TIMESTAMPTZ,
  owner_generation INTEGER
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
    ps.auth,
    c.claimed_at,
    ps.owner_generation
  FROM claimed c
  JOIN public.notifications n ON n.id = c.notification_id
  JOIN public.push_subscriptions ps ON ps.id = c.push_subscription_id;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_notification_push_deliveries(INTEGER, TIMESTAMPTZ, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_notification_push_deliveries(INTEGER, TIMESTAMPTZ, BOOLEAN) TO service_role;

-- 4) Single-transaction fenced write-back (api/003 §Delivery and
-- concurrency): every post-provider state transition must compare the full
-- lease identity (id, status='processing', claimed_at, attempts) AND the
-- subscription's current owner_generation against claim-time values, so a
-- stale worker whose lease was stolen or whose endpoint moved mid-flight
-- cannot overwrite the new lease's result. Returns false when the worker
-- lost the race — callers must surface that as skipped work, never as a
-- successful classification.
--
-- status = 'endpoint_invalid' additionally deletes the subscription inside
-- the same transaction, and ONLY after the fenced transition succeeded: a
-- stale worker therefore never deletes a subscription claimed by a newer
-- lease. notification_push_deliveries rows are kept as audit metadata (the
-- table intentionally has no FK).
CREATE OR REPLACE FUNCTION public.settle_push_delivery(
  p_delivery_id UUID,
  p_claimed_at TIMESTAMPTZ,
  p_attempts INTEGER,
  p_owner_generation INTEGER,
  p_subscription_id UUID,
  p_status TEXT,
  p_error_code TEXT,
  p_sent_at TIMESTAMPTZ DEFAULT NULL,
  p_available_at TIMESTAMPTZ DEFAULT NULL,
  p_now TIMESTAMPTZ DEFAULT timezone('utc', now())
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_updated INTEGER := 0;
BEGIN
  IF p_status NOT IN ('sent', 'pending', 'dead_letter', 'endpoint_invalid') THEN
    RAISE EXCEPTION 'invalid_delivery_status';
  END IF;

  UPDATE public.notification_push_deliveries d
     SET status = p_status,
         last_error_code = p_error_code,
         sent_at = COALESCE(p_sent_at, d.sent_at),
         available_at = COALESCE(p_available_at, d.available_at),
         updated_at = p_now
   WHERE d.id = p_delivery_id
     AND d.status = 'processing'
     AND d.claimed_at IS NOT DISTINCT FROM p_claimed_at
     AND d.attempts = p_attempts
     AND EXISTS (
       SELECT 1
         FROM public.push_subscriptions ps
        WHERE ps.id = d.push_subscription_id
          AND ps.id = p_subscription_id
          AND ps.owner_generation = p_owner_generation
     );

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    RETURN FALSE;
  END IF;

  IF p_status = 'endpoint_invalid' THEN
    DELETE FROM public.push_subscriptions WHERE id = p_subscription_id;
  END IF;

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.settle_push_delivery(UUID, TIMESTAMPTZ, INTEGER, INTEGER, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.settle_push_delivery(UUID, TIMESTAMPTZ, INTEGER, INTEGER, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ) TO service_role;

COMMIT;
