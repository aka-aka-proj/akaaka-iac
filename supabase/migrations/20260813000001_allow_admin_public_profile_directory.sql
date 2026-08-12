-- Expose only the fields required by the authenticated public directory.
-- Keep profiles RLS unchanged so admins do not gain direct access to other
-- users' profile rows or private fields through the base table.
DROP VIEW IF EXISTS public.public_profiles;

CREATE VIEW public.public_profiles
WITH (security_invoker = false, security_barrier = true)
AS
SELECT
  id,
  display_name,
  metadata ->> 'avatar_path' AS avatar_path
FROM public.profiles;

REVOKE ALL ON TABLE public.public_profiles FROM anon;
GRANT SELECT ON TABLE public.public_profiles TO authenticated;
