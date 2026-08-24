-- Spec 006 (event publication control): 草稿不得預約公開 — table-level invariant.
--
-- 20260825000000 guards set_event_publication only. Authenticated clients hold
-- INSERT/UPDATE on public.events and RLS is owner-scoped, so a dead schedule
-- could still be produced by (a) inserting a draft that already carries
-- publish_at/unpublish_at, or (b) downgrading lifecycle_status to 'draft'
-- while keeping an existing schedule — trg_prevent_direct_event_publication_update
-- is UPDATE-only and fires solely when the publication tuple changes.
-- This migration backfills any such rows again (idempotent alongside the RPC
-- migration's own backfill) and enforces the invariant for every writer via a
-- CHECK constraint, independent of merge order with 20260825000000.
--
-- Docs: akaaka-docs docs/spec/features/events/006-event-publication-control-spec.md

BEGIN;

SELECT set_config('app.event_publication_rpc', 'on', true);

UPDATE public.events
SET publish_at = NULL,
    unpublish_at = NULL,
    updated_at = timezone('utc', now())
WHERE lifecycle_status = 'draft'
  AND (publish_at IS NOT NULL OR unpublish_at IS NOT NULL);

ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_draft_without_publication_schedule,
  ADD CONSTRAINT events_draft_without_publication_schedule
    CHECK (
      lifecycle_status <> 'draft'
      OR (publish_at IS NULL AND unpublish_at IS NULL)
    );

COMMIT;
