ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_source_url_check;

ALTER TABLE public.events
  ADD CONSTRAINT events_source_url_check
  CHECK (
    source_url IS NULL
    OR source_url ~ '^https://(x|twitter)\\.com/[^/]+/status/[0-9]+$'
    OR source_url ~ '^https://todo\\.smertw\\.com/events/[0-9]+$'
    OR source_url ~ '^https://docs\\.google\\.com/forms/[^/]+(/[^/]*)*$'
  );
