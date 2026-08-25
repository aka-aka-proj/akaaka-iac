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
  v_target_id UUID;
  v_target_owner UUID;
  v_purge UUID[];
  v_seen INTEGER;
  r RECORD;
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

  -- Serialize every RPC touching the same endpoint: without it, two fresh
  -- subscribes for one endpoint could both take the insert path during the
  -- expand window (no single-column unique yet) and recreate duplicates.
  PERFORM pg_advisory_xact_lock(hashtextextended(trim(p_endpoint), 0));

  -- The expand window legitimately allows one row per legacy profile for the
  -- same endpoint. Selection is strictly prioritized: the caller's OWN row
  -- always wins the target slot regardless of recency (a newer possession-
  -- matched foreign row must never displace it, otherwise the later ownership
  -- update collides with the still-present own row); otherwise the newest row
  -- whose key material matches proves possession and becomes the transfer
  -- target. Rows that are neither get quarantined and collapsed — but only
  -- possession-matched extras or the caller's own extras; a foreign row whose
  -- keys do NOT match stays untouched, because deleting it without holding
  -- its keys would let anyone nuke another profile's live binding.
  v_target_id := NULL;
  v_target_owner := NULL;
  v_purge := ARRAY[]::UUID[];
  v_seen := 0;

  FOR r IN
    SELECT ps.id, ps.profile_id, ps.p256dh, ps.auth
      FROM public.push_subscriptions ps
     WHERE ps.endpoint = trim(p_endpoint)
      ORDER BY ps.updated_at DESC, ps.created_at DESC, ps.id
       FOR UPDATE
  LOOP
    v_seen := v_seen + 1;

    IF r.profile_id = v_profile_id THEN
      -- Own row always displaces a previously picked possession-matched
      -- foreign candidate; the displaced row itself proved possession via
      -- the supplied keys, so collapsing it stays legal.
      IF v_target_id IS NOT NULL THEN
        v_purge := array_append(v_purge, v_target_id);
      END IF;
      v_target_id := r.id;
      v_target_owner := r.profile_id;
    ELSIF r.p256dh = trim(p_p256dh) AND r.auth = trim(p_auth) THEN
      IF v_target_id IS NULL THEN
        v_target_id := r.id;
        v_target_owner := r.profile_id;
      ELSE
        v_purge := array_append(v_purge, r.id);
      END IF;
    END IF;
    -- Foreign rows whose keys do not match are left completely untouched:
    -- deleting them without holding their key material would let any
    -- authenticated caller destroy another profile's live binding.
  END LOOP;

  IF v_seen = 0 THEN
    INSERT INTO public.push_subscriptions (
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
    RETURNING id INTO v_subscription_id;
    RETURN v_subscription_id;
  END IF;

  -- Refresh mode is a passive session-start call: whenever the endpoint turns
  -- out to be held by another profile — whether or not any row matched the
  -- supplied keys — it must never acquire or mutate anything; it reports
  -- not-owned as NULL so the client silently skips.
  IF p_mode = 'refresh'
     AND (v_target_id IS NULL OR v_target_owner <> v_profile_id) THEN
    RETURN NULL;
  END IF;

  -- No row matched the caller identity or possession proof: reject without
  -- touching anything. Purging below is only legal once a proven target
  -- exists, otherwise a failed hijack attempt would destroy real bindings.
  IF v_target_id IS NULL THEN
    RAISE EXCEPTION 'endpoint_conflict';
  END IF;

  -- Same owner re-subscribing (session refresh, key rotation): update in
  -- place and keep the row fresh against the cleanup threshold. Ownership
  -- did not change, so owner_generation stays put.
  IF v_target_owner = v_profile_id THEN
    UPDATE public.push_subscriptions
       SET p256dh = trim(p_p256dh),
           auth = trim(p_auth),
           user_agent = p_user_agent,
           updated_at = timezone('utc', now())
     WHERE id = v_target_id
    RETURNING id INTO v_subscription_id;

    UPDATE public.notification_push_deliveries
       SET status = 'cancelled',
           last_error_code = 'duplicate_collapsed',
           updated_at = timezone('utc', now())
     WHERE push_subscription_id = ANY(v_purge)
       AND status IN ('pending', 'processing');

    DELETE FROM public.push_subscriptions WHERE id = ANY(v_purge);

    RETURN v_subscription_id;
  END IF;

  -- Cross-profile transfer demands possession proof: key material only
  -- exists inside the real browser subscription, so "knowing the endpoint"
  -- must never be enough to take it over.
  --
  -- Serialize against BOTH the claim path and the fan-out enqueue on every
  -- delivery row of the target and of every collapsed duplicate: taking the
  -- same row locks claim uses (FOR UPDATE) blocks claim mid-flight, and the
  -- enqueue trigger now also locks the subscription row before inserting, so
  -- no phantom delivery can appear after this scan. Then defer while any
  -- unexpired send lease — target or purge — still has a worker mid-send.
  PERFORM 1
    FROM public.notification_push_deliveries d
   WHERE d.push_subscription_id = v_target_id
      OR d.push_subscription_id = ANY(v_purge)
    ORDER BY d.id
       FOR UPDATE;

  IF EXISTS (
    SELECT 1
      FROM public.notification_push_deliveries d
     WHERE (d.push_subscription_id = v_target_id
            OR d.push_subscription_id = ANY(v_purge))
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
   WHERE id = v_target_id
  RETURNING id INTO v_subscription_id;

  -- Quarantine outstanding deliveries of the previous owner inside the same
  -- transaction, collapse stale duplicate bindings, and drop their rows.
  -- Already-terminal rows stay untouched as audit history.
  UPDATE public.notification_push_deliveries
     SET status = 'cancelled',
         last_error_code = 'endpoint_moved',
         updated_at = timezone('utc', now())
   WHERE push_subscription_id = v_target_id
     AND status IN ('pending', 'processing');

  UPDATE public.notification_push_deliveries
     SET status = 'cancelled',
         last_error_code = 'duplicate_collapsed',
         updated_at = timezone('utc', now())
   WHERE push_subscription_id = ANY(v_purge)
     AND status IN ('pending', 'processing');

  DELETE FROM public.push_subscriptions WHERE id = ANY(v_purge);

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
    COALESCE(n.event_id, ea.event_id),
    n.actor_profile_id,
    n.venue_application_profile_id,
    ps.endpoint,
    ps.p256dh,
    ps.auth,
    c.claimed_at,
    ps.owner_generation
  FROM claimed c
  JOIN public.notifications n ON n.id = c.notification_id
  LEFT JOIN public.event_announcements ea ON ea.id = n.event_announcement_id
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
