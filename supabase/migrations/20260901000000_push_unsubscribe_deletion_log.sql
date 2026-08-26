-- Push subscription controlled revocation + deletion tombstones (#100 prerequisites).
--
-- api/004 §Validation rules "無主重建條件" / "撤銷意圖優先於清理來源":
--   1) push_subscriptions_deletion_log: endpoint-keyed tombstone recording why
--      a binding disappeared, keeping a one-way key-material fingerprint so
--      only the proven last owner can passively rebuild or record revocation.
--   2) unsubscribe_push_subscription: the only authorized explicit-disable
--      path; SECURITY DEFINER, possession-proof gated, defers while an
--      unexpired delivery send lease is active (revocation_deferred), and
--      writes/overwrites the tombstone with deletion_source='user_revoked'
--      in the same transaction.
--   3) cleanup_stale_push_subscriptions now leaves a 'scheduled_cleanup'
--      tombstone in the same transaction as each delete, never overwriting
--      a residual 'user_revoked' marker.
--   4) subscribe_push_subscription refresh mode rebuilds a deleted binding
--      only when the tombstone proves scheduled_cleanup + same last owner +
--      matching fingerprint; every other no-row refresh returns NULL instead
--      of silently creating a binding. Any successful subscribe retires the
--      residual tombstone for its endpoint.
--
-- Expand-only: no constraint is tightened and no table privilege is removed,
-- so legacy direct-INSERT frontends keep working across the rollout window.

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS public.push_subscriptions_deletion_log (
  endpoint TEXT PRIMARY KEY,
  last_owner_profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  deletion_source TEXT NOT NULL
    CHECK (deletion_source IN ('scheduled_cleanup', 'user_revoked')),
  key_material_fingerprint TEXT NOT NULL,
  deleted_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT push_subscriptions_deletion_log_endpoint_not_blank CHECK (length(trim(endpoint)) > 0)
);

-- Support index: last_owner_profile_id carries profiles ON DELETE CASCADE and
-- unreconstructed revocation/cleanup tombstones accumulate forever, so every
-- account deletion would otherwise cascade via a full tombstone scan.
CREATE INDEX IF NOT EXISTS idx_push_subscriptions_deletion_log_last_owner
  ON public.push_subscriptions_deletion_log (last_owner_profile_id);

ALTER TABLE public.push_subscriptions_deletion_log ENABLE ROW LEVEL SECURITY;

-- Deny-by-default: browser roles get nothing; access happens only inside
-- definer routines running as the table owner (RLS matrix final state).
REVOKE ALL ON public.push_subscriptions_deletion_log FROM anon;
REVOKE ALL ON public.push_subscriptions_deletion_log FROM authenticated;

-- One-way fingerprint of the key material pair (database/001 canonical
-- definition). Values are trim()-normalized to match the RPC equality
-- semantics, then framed with explicit lengths so different (p256dh, auth)
-- splits can never hash the same input. Never exposed to callers:
-- definer-internal comparison input only.
CREATE OR REPLACE FUNCTION public.push_subscription_key_fingerprint(
  p_p256dh TEXT,
  p_auth TEXT
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT encode(
    digest(
      'push-sub-key-v1:'
        || length(trim(p_p256dh))::text || ':' || trim(p_p256dh)
        || length(trim(p_auth))::text || ':' || trim(p_auth),
      'sha256'
    ),
    'hex'
  )
$$;

REVOKE ALL ON FUNCTION public.push_subscription_key_fingerprint(TEXT, TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.unsubscribe_push_subscription(
  p_endpoint TEXT,
  p_p256dh TEXT,
  p_auth TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_profile_id UUID;
  v_row public.push_subscriptions%ROWTYPE;
  v_tomb_owner UUID;
  v_tomb_fingerprint TEXT;
BEGIN
  v_profile_id := auth.uid();
  IF v_profile_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  -- Revocation is destructive, so it demands the same possession proof as
  -- subscribing: knowing the endpoint alone must never suffice to kill or
  -- mark another profile's binding (revoke-DoS guard, api/004 §Request).
  IF p_endpoint IS NULL OR length(trim(p_endpoint)) = 0
     OR p_p256dh IS NULL OR length(trim(p_p256dh)) = 0
     OR p_auth IS NULL OR length(trim(p_auth)) = 0 THEN
    RAISE EXCEPTION 'invalid_subscription_payload';
  END IF;

  -- Same serialization domain as subscribe: concurrent unsubscribe/subscribe
  -- for one endpoint collapse into a fixed order.
  PERFORM pg_advisory_xact_lock(hashtextextended(trim(p_endpoint), 0));

  SELECT * INTO v_row
    FROM public.push_subscriptions
   WHERE endpoint = trim(p_endpoint)
   FOR UPDATE;

  IF FOUND THEN
    IF v_row.profile_id = v_profile_id
       AND v_row.p256dh = trim(p_p256dh)
       AND v_row.auth = trim(p_auth) THEN
      -- Same fencing domain as the ownership move and cleanup: lock this
      -- binding's delivery rows first so an uncommitted pending→processing
      -- claim flip becomes visible to the predicate below, then defer while
      -- an unexpired send lease still has a worker mid-send. Without this,
      -- a worker past its final subscription re-read would keep sending to
      -- an endpoint the user has just explicitly disabled.
      PERFORM 1
        FROM public.notification_push_deliveries d
       WHERE d.push_subscription_id = v_row.id
       ORDER BY d.id
          FOR UPDATE;

      IF EXISTS (
        SELECT 1
          FROM public.notification_push_deliveries d
         WHERE d.push_subscription_id = v_row.id
           AND d.status = 'processing'
           AND d.claimed_at >= timezone('utc', now()) - interval '5 minutes'
      ) THEN
        RAISE EXCEPTION 'revocation_deferred';
      END IF;

      DELETE FROM public.push_subscriptions WHERE id = v_row.id;

      INSERT INTO public.push_subscriptions_deletion_log (
        endpoint, last_owner_profile_id, deletion_source, key_material_fingerprint
      )
      VALUES (
        trim(p_endpoint),
        v_profile_id,
        'user_revoked',
        public.push_subscription_key_fingerprint(p_p256dh, p_auth)
      )
      ON CONFLICT (endpoint) DO UPDATE
        SET last_owner_profile_id = EXCLUDED.last_owner_profile_id,
            deletion_source = EXCLUDED.deletion_source,
            key_material_fingerprint = EXCLUDED.key_material_fingerprint,
            deleted_at = timezone('utc', now());

      RETURN true;
    END IF;

    -- Foreign row (whatever the supplied keys) or wrong keys on own row:
    -- reject without revealing which predicate failed.
    RAISE EXCEPTION 'endpoint_conflict';
  END IF;

  -- Row already gone: only the recorded last owner holding key material that
  -- still matches the stored fingerprint may overwrite the marker with
  -- user_revoked (revocation intent outranks scheduled_cleanup). Idempotent:
  -- re-calls by the same owner keep returning true.
  SELECT last_owner_profile_id, key_material_fingerprint
    INTO v_tomb_owner, v_tomb_fingerprint
    FROM public.push_subscriptions_deletion_log
   WHERE endpoint = trim(p_endpoint);

  IF v_tomb_owner IS NOT DISTINCT FROM v_profile_id
     AND v_tomb_fingerprint = public.push_subscription_key_fingerprint(p_p256dh, p_auth) THEN
    UPDATE public.push_subscriptions_deletion_log
       SET deletion_source = 'user_revoked',
           deleted_at = timezone('utc', now())
     WHERE endpoint = trim(p_endpoint);
    RETURN true;
  END IF;

  RAISE EXCEPTION 'endpoint_conflict';
END;
$$;

REVOKE ALL ON FUNCTION public.unsubscribe_push_subscription(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unsubscribe_push_subscription(TEXT, TEXT, TEXT) TO authenticated;

-- Cleanup now records WHY each deleted binding disappeared, in the same
-- transaction as the delete: a crash between delete and marker would leave
-- an untraceable endpoint that refresh must never rebuild from.
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

  -- Serialize against concurrent claim transitions first: lock every
  -- candidate's still-live delivery rows so an uncommitted pending→processing
  -- flip becomes visible to the predicate evaluation that follows, instead of
  -- racing past it and deleting a subscription mid-send.
  PERFORM 1
    FROM public.notification_push_deliveries d
    JOIN public.push_subscriptions ps ON ps.id = d.push_subscription_id
   WHERE ps.updated_at < v_cutoff
     AND d.status IN ('pending', 'processing')
    ORDER BY d.id
       FOR UPDATE OF d;

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
      -- Mirror the move path's lease guard: never delete a subscription
      -- while an unexpired processing lease may have a worker mid-send.
      AND NOT EXISTS (
        SELECT 1
        FROM public.notification_push_deliveries d
        WHERE d.push_subscription_id = ps.id
          AND d.status = 'processing'
          AND d.claimed_at >= timezone('utc', now()) - interval '5 minutes'
      )
    RETURNING ps.endpoint, ps.profile_id, ps.p256dh, ps.auth
  ), marked AS (
    INSERT INTO public.push_subscriptions_deletion_log (
      endpoint, last_owner_profile_id, deletion_source, key_material_fingerprint
    )
    SELECT endpoint,
           profile_id,
           'scheduled_cleanup',
           public.push_subscription_key_fingerprint(p256dh, auth)
      FROM deleted
    -- Revocation intent outranks cleanup origin: a residual user_revoked
    -- marker (legacy direct-INSERT rebuilt row later cleaned up) must keep
    -- its original owner and fingerprint, or a matching refresh could
    -- resurrect an endpoint the user explicitly disabled.
    ON CONFLICT (endpoint) DO UPDATE
      SET last_owner_profile_id = EXCLUDED.last_owner_profile_id,
          deletion_source = EXCLUDED.deletion_source,
          key_material_fingerprint = EXCLUDED.key_material_fingerprint,
          deleted_at = timezone('utc', now())
      WHERE public.push_subscriptions_deletion_log.deletion_source <> 'user_revoked'
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

-- Rebuild wiring inside subscribe: the no-row branch gains the passive-path
-- gate (refresh) and retires stale tombstones on every successful bind.
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
  v_tomb_owner UUID;
  v_tomb_fingerprint TEXT;
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
    -- Passive session-start refresh must never conjure a subscription into
    -- existence: rebuilding a deleted binding is legal solely when the
    -- tombstone proves scheduled_cleanup removed it while this exact profile
    -- was the last owner and the supplied keys match the stored fingerprint.
    -- User-revoked markers and unknown-origin deletions stay dead; standard
    -- mode keeps creating fresh bindings (explicit user intent).
    IF p_mode = 'refresh' THEN
      -- Only a scheduled_cleanup marker may back a passive rebuild; a
      -- user_revoked marker (explicit disable intent) or an unknown origin
      -- must keep the endpoint dead no matter who calls.
      SELECT last_owner_profile_id, key_material_fingerprint
        INTO v_tomb_owner, v_tomb_fingerprint
        FROM public.push_subscriptions_deletion_log
       WHERE endpoint = trim(p_endpoint)
         AND deletion_source = 'scheduled_cleanup';

      IF v_tomb_owner IS NULL
         OR v_tomb_owner <> v_profile_id
         OR v_tomb_fingerprint <> public.push_subscription_key_fingerprint(p_p256dh, p_auth) THEN
        RETURN NULL;
      END IF;
    END IF;

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

    -- Any successful bind for this endpoint retires stale tombstones so they
    -- cannot accumulate behind live bindings.
    DELETE FROM public.push_subscriptions_deletion_log
     WHERE endpoint = trim(p_endpoint);

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

    -- A successful re-bind also retires any stale marker left behind by the
    -- direct-INSERT transition window.
    DELETE FROM public.push_subscriptions_deletion_log
     WHERE endpoint = trim(p_endpoint);

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

  DELETE FROM public.push_subscriptions_deletion_log
   WHERE endpoint = trim(p_endpoint);

  RETURN v_subscription_id;
END;
$$;

REVOKE ALL ON FUNCTION public.subscribe_push_subscription(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.subscribe_push_subscription(TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;
