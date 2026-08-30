-- The GitHub Actions scheduler is the active Web Push delivery scheduler.
-- The earlier pg_cron migration is retained for migration-history integrity,
-- but its job must be removed so an environment that applies both versions
-- cannot deliver the same outbox through two competing schedulers.

DO $$
DECLARE
  existing_job BIGINT;
BEGIN
  SELECT jobid
  INTO existing_job
  FROM cron.job
  WHERE jobname = 'akaaka-web-push-delivery'
  LIMIT 1;

  IF existing_job IS NOT NULL THEN
    PERFORM cron.unschedule(existing_job);
  END IF;
END
$$;
