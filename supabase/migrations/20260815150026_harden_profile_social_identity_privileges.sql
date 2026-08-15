-- Existing exposed-table grants can apply to newly created public tables.
-- Keep browser access read-only; the controlled backend remains service_role.
REVOKE ALL ON TABLE public.profile_social_identities FROM anon, authenticated;
GRANT SELECT ON TABLE public.profile_social_identities TO authenticated;
GRANT ALL ON TABLE public.profile_social_identities TO service_role;
