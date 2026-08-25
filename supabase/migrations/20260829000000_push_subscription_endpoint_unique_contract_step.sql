-- Contract-step (api/004 §Rollout ordering step 3): enforce global endpoint
-- uniqueness so one browser subscription can only ever be bound to one
-- profile at a time, and close direct client INSERT now that
-- subscribe_push_subscription owns all subscription creation.
--
-- Deliberately NOT part of this step (Phase A scope):
--   * UPDATE stays open until subscribe_push_subscription grows the p_mode
--     refresh path (frontend#92 / iac push-subscription-p-mode work).
--   * DELETE stays open until unsubscribe_push_subscription and its deletion
--     log exist — closing it first would leave users without any unsubscribe
--     path (api/004 §Validation rules; RLS matrix final state).
--
-- Rollout gate: frontend consumer release consuming expand is live
-- (subscribe via RPC since #83, session-start refresh on preview); the
-- expand→contract window re-created duplicates only through legacy INSERT,
-- which this step closes.
--
-- Contracts: akaaka-docs docs/spec/api/004-web-push-subscription-hygiene.md
-- §Rollout ordering / §Compatibility, ADR-021 §Migration / rollout.
-- Issues: aka-aka-proj/akaaka-iac#87, #93.

BEGIN;

-- Re-run the preflight dedupe: during the expand→contract window legacy
-- bundles could still direct-INSERT the same endpoint under two profiles,
-- and ADD CONSTRAINT would fail on such rows. Keep exactly the newest row
-- per endpoint with a deterministic tiebreaker; deliveries reference
-- subscriptions without a hard FK by design (#62), so discarded rows leave
-- no orphans behind.
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

REVOKE INSERT ON public.push_subscriptions FROM authenticated;

COMMIT;
