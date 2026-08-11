-- Exposed table privileges are separate from RLS policy enforcement.
-- Keep profile rows inaccessible to anonymous clients and let the existing
-- policies decide which authenticated rows are visible or writable.
REVOKE ALL ON TABLE public.profiles FROM anon;
REVOKE ALL ON TABLE public.profiles FROM authenticated;
REVOKE ALL ON TABLE public.profiles FROM service_role;

GRANT SELECT, INSERT, UPDATE ON TABLE public.profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.profiles TO service_role;
