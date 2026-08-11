-- The security matrix exposes only aggregate profile report counts to clients.
GRANT SELECT ON public.profile_report_stats TO authenticated;
GRANT SELECT ON public.profile_report_stats TO service_role;
REVOKE ALL ON public.profile_report_stats FROM anon;
