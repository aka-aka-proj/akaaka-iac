-- Move stale Web Push subscription cleanup from GitHub Actions to Supabase pg_cron.
-- The cleanup is database-local, so scheduling the RPC directly avoids a hosted
-- runner, an HTTP hop through the Edge Function, and GitHub scheduler secrets.
-- Preserve the existing production cadence: 18:17 UTC daily.

create extension if not exists pg_cron with schema pg_catalog;

do $$
declare
  existing_job bigint;
begin
  select jobid
  into existing_job
  from cron.job
  where jobname = 'akaaka-web-push-subscription-cleanup'
  limit 1;

  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;
end
$$;

select cron.schedule(
  'akaaka-web-push-subscription-cleanup',
  '17 18 * * *',
  $cron$
    select public.cleanup_stale_push_subscriptions(90);
  $cron$
);
