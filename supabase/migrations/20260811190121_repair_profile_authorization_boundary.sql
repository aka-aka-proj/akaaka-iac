-- The PostgreSQL session role claim is normally "authenticated". AkaAka's
-- platform-admin claim lives in the trusted JWT app_metadata object.
DROP POLICY IF EXISTS profiles_read_non_admin ON public.profiles;
CREATE POLICY profiles_read_non_admin ON public.profiles
  FOR SELECT TO authenticated
  USING (COALESCE((select auth.jwt() -> 'app_metadata' ->> 'role'), '') <> 'admin');

DROP POLICY IF EXISTS profiles_read_self_admin ON public.profiles;
CREATE POLICY profiles_read_self_admin ON public.profiles
  FOR SELECT TO authenticated
  USING (
    (select auth.uid()) = id
    AND (select auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  );

-- Client profile writes must not be able to change protected business or audit
-- fields. RLS remains responsible for restricting the row to auth.uid().
REVOKE INSERT, UPDATE ON TABLE public.profiles FROM authenticated;
GRANT INSERT (id, display_name, bio, external_social_links, metadata, venue_metadata)
  ON TABLE public.profiles TO authenticated;
GRANT UPDATE (display_name, bio, external_social_links, metadata, venue_metadata)
  ON TABLE public.profiles TO authenticated;
