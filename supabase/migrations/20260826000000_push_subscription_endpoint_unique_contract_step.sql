-- Issue #62 contract step: enforce global endpoint uniqueness so one browser
-- subscription can only ever be bound to one profile at a time.
--
-- Rollout gate: tightening change — must only reach production after the
-- frontend consumer release (subscribe_push_subscription adoption plus
-- session-start refresh) has been deployed successfully. Direct client
-- INSERT against an endpoint owned by another profile fails from here on;
-- ownership transfer goes exclusively through subscribe_push_subscription.
-- The legacy composite UNIQUE stays as a redundant compatibility layer for
-- older client conflict targets; authorization remains defined by RLS.
--
-- Contracts: akaaka-docs docs/spec/api/004-web-push-subscription-hygiene.md
-- §Compatibility / versioning, ADR-021 §Migration / rollout.

-- Re-dedupe first: rows created by pre-RPC clients during the expand-to-
-- contract window can hold the same endpoint under two profiles, and ADD
-- CONSTRAINT would fail on them. Keep the newest row per endpoint; audit
-- deliveries of discarded rows stay intact (no foreign key by design).
DELETE FROM public.push_subscriptions a
USING public.push_subscriptions b
WHERE a.endpoint = b.endpoint
  AND (b.updated_at, b.created_at, b.id) > (a.updated_at, a.created_at, a.id);

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
