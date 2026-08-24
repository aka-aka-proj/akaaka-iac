BEGIN;

SELECT plan(3);

-- Contract suite for the draft/publication-schedule table invariant
-- (docs/spec/features/events/006-event-publication-control-spec.md).
-- The RPC-level guard is covered by draft_publication_schedule_guard_test.sql;
-- this suite pins the table-level CHECK that also covers direct INSERT/UPDATE.

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.events'::regclass
      AND conname = 'events_draft_without_publication_schedule'
      AND contype = 'c'
      AND convalidated
  ),
  'events carries a validated no-schedule-on-draft CHECK constraint'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.events'::regclass
      AND conname = 'events_draft_without_publication_schedule'
      AND pg_get_constraintdef(oid) LIKE '%lifecycle_status%'
      AND pg_get_constraintdef(oid) LIKE '%publish_at%'
      AND pg_get_constraintdef(oid) LIKE '%unpublish_at%'
  ),
  'the constraint keys on draft lifecycle status and both schedule columns'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM public.events
    WHERE lifecycle_status = 'draft'
      AND (publish_at IS NOT NULL OR unpublish_at IS NOT NULL)
  ),
  'no draft event carries a dead publication schedule after backfill'
);

SELECT * FROM finish();
ROLLBACK;
