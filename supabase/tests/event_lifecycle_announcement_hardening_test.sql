BEGIN;

SELECT plan(6);

-- Contract suite for the lifecycle/announcement hardening (PR #53 review round):
-- 1) published events cannot re-enter draft through generic UPDATE,
-- 2) block-pair lookups are restricted to pair endpoints for JWT callers,
-- 3) announcement publisher locks the event row alongside the announcement,
-- 4) the cron wrapper retries only the frequency conflict (SQLSTATE P1500).

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.events'::regclass
      AND tgname = 'trg_enforce_event_lifecycle_transition'
      AND NOT tgisinternal
  ),
  'events carries the lifecycle transition guard trigger'
);

SELECT ok(
  (
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    WHERE p.oid = 'public.enforce_event_lifecycle_transition()'::regprocedure
  ) LIKE '%published events cannot return to draft%',
  'lifecycle guard rejects non-draft to draft downgrades'
);

SELECT ok(
  (
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    WHERE p.oid = 'public.blocks_pair_either_direction(uuid, uuid)'::regprocedure
  ) LIKE '%auth.uid() IS NOT NULL AND auth.uid() <> p_left AND auth.uid() <> p_right%'
  AND (
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    WHERE p.oid = 'public.blocks_pair_either_direction(uuid, uuid)'::regprocedure
  ) LIKE '%42501%',
  'block-pair helper restricts JWT callers to pair endpoints'
);

SELECT ok(
  (
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    WHERE p.oid = 'public.publish_event_announcement_internal(uuid, timestamptz)'::regprocedure
  ) LIKE '%FOR UPDATE OF a, e%',
  'announcement publisher locks the event row with the announcement row'
);

SELECT ok(
  (
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    WHERE p.oid = 'public.publish_event_announcement_internal(uuid, timestamptz)'::regprocedure
  ) LIKE '%event announcement frequency limit exceeded%'
  AND (
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    WHERE p.oid = 'public.publish_event_announcement_internal(uuid, timestamptz)'::regprocedure
  ) LIKE '%P1500%',
  'frequency conflicts carry the retryable SQLSTATE P1500'
);

SELECT ok(
  (
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    WHERE p.oid = 'public.publish_due_event_announcements()'::regprocedure
  ) LIKE '%SQLSTATE <> ''P1500''%'
  AND (
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    WHERE p.oid = 'public.publish_due_event_announcements()'::regprocedure
  ) LIKE '%%RAISE;%',
  'cron wrapper re-raises every failure except the retryable conflict'
);

SELECT * FROM finish();
ROLLBACK;
