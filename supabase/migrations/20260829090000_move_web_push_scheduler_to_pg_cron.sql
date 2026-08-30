-- Move Web Push delivery scheduling from GitHub-hosted runners to Supabase.
-- The scheduler invokes the existing deliver-web-push Edge Function every five minutes.
--
-- Required Vault secrets (configured per environment, outside source control):
--   web_push_delivery_url
--   web_push_delivery_token

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

do $$
declare
  existing_job bigint;
begin
  select jobid into existing_job
  from cron.job
  where jobname = 'akaaka-web-push-delivery'
  limit 1;

  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;
end
$$;

select cron.schedule(
  'akaaka-web-push-delivery',
  '*/5 * * * *',
  $cron$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'web_push_delivery_url' limit 1),
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'web_push_delivery_token' limit 1),
        'Content-Type', 'application/json'
      ),
      body := '{"limit":100}'::jsonb
    )
    where exists (select 1 from vault.decrypted_secrets where name = 'web_push_delivery_url')
      and exists (select 1 from vault.decrypted_secrets where name = 'web_push_delivery_token');
  $cron$
);
