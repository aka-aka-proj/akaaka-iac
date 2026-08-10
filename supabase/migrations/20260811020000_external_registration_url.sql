ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS external_registration_url TEXT;

ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_external_registration_url_check;

ALTER TABLE public.events
  ADD CONSTRAINT events_external_registration_url_check
  CHECK (
    external_registration_url IS NULL
    OR external_registration_url ~ '^https://docs\\.google\\.com/(forms|document)/'
  );
