-- Issue #62: push_subscriptions endpoint uniqueness and lifecycle cleanup.
-- Contracts: akaaka-docs docs/spec/api/004-web-push-subscription-hygiene.md,
-- docs/spec/database/001-akaaka-supabase-schema.md, ADR-021.

-- 1) Dedupe historical rows before enforcing global endpoint uniqueness.
-- Keep exactly one row per endpoint: the newest by updated_at, with a
-- deterministic tie-breaker for rows written in the same statement.
DELETE FROM public.push_subscriptions a
USING public.push_subscriptions b
WHERE a.endpoint = b.endpoint
  AND (b.updated_at, b.created_at, b.id) > (a.updated_at, a.created_at, a.id);

-- 2) Global endpoint uniqueness: one browser subscription can only ever be
-- bound to one profile at a time. The legacy composite UNIQUE stays as a
-- redundant compatibility layer for existing client conflict targets;
-- authorization remains defined by RLS, not by these constraints.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.push_subscriptions'::regclass
      AND conname = 'push_subscriptions_endpoint_unique'
  ) THEN
    ALTER TABLE public.push_subscriptions
      ADD CONSTRAINT push_subscriptions_endpoint_unique UNIQUE (endpoint);
  END IF;
END
$$;

-- 3) Controlled subscription write path. Cross-profile ownership transfer is
-- only possible through this SECURITY DEFINER function; direct client INSERTs
-- fail on the unique constraint when another profile holds the endpoint.
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

  INSERT INTO public.push_subscriptions AS ps (
    profile_id,
    endpoint,
    p256dh,
    auth,
    user_agent
  )
  VALUES (
    v_profile_id,
    p_endpoint,
    trim(p_p256dh),
    trim(p_auth),
    p_user_agent
  )
  ON CONFLICT (endpoint) DO UPDATE
  SET profile_id = EXCLUDED.profile_id,
      p256dh = EXCLUDED.p256dh,
      auth = EXCLUDED.auth,
      user_agent = EXCLUDED.user_agent,
      updated_at = timezone('utc', now())
  RETURNING ps.id INTO v_subscription_id;

  RETURN v_subscription_id;
END;
$$;

REVOKE ALL ON FUNCTION public.subscribe_push_subscription(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.subscribe_push_subscription(TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- 4) Scheduled hygiene: delete subscriptions that have not been refreshed
-- within the threshold. Pure database-side cleanup; provider revocation
-- (404/410) stays with the delivery fan-out worker. Bounded input prevents a
-- misconfigured scheduler from wiping active subscriptions.
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
BEGIN
  IF p_stale_days IS NULL OR p_stale_days < 30 OR p_stale_days > 730 THEN
    RAISE EXCEPTION 'invalid_stale_days';
  END IF;

  WITH deleted AS (
    DELETE FROM public.push_subscriptions
    WHERE updated_at < timezone('utc', now()) - (p_stale_days * interval '1 day')
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
