-- The exposed-table grant migration intentionally revoked all authenticated
-- table privileges first. Restore the profile-specific boundary explicitly.
GRANT SELECT ON TABLE public.profiles TO authenticated;
GRANT INSERT (id, display_name, bio, external_social_links, metadata, venue_metadata)
  ON TABLE public.profiles TO authenticated;
GRANT UPDATE (display_name, bio, external_social_links, metadata, venue_metadata)
  ON TABLE public.profiles TO authenticated;

REVOKE ALL ON TABLE public.profiles FROM anon;
