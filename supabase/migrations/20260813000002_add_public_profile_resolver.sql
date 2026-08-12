-- Public profile lookup for authenticated profile links, including admin review.
-- The function intentionally exposes only fields already governed by profile visibility.
CREATE OR REPLACE FUNCTION public.get_public_profile(target_profile_id UUID)
RETURNS TABLE (
  id UUID,
  role_status TEXT,
  display_name TEXT,
  bio TEXT,
  external_social_links JSONB,
  metadata JSONB,
  reputation_score INTEGER
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    p.id,
    p.role_status,
    p.display_name,
    CASE
      WHEN COALESCE(p.metadata -> 'visibility' ->> 'bio', 'public') = 'public' THEN p.bio
      ELSE NULL
    END,
    p.external_social_links,
    jsonb_strip_nulls(jsonb_build_object(
      'visibility', COALESCE(p.metadata -> 'visibility', '{}'::jsonb),
      'gender_identity', CASE
        WHEN COALESCE(p.metadata -> 'visibility' ->> 'gender_identity', 'public') = 'public'
        THEN p.metadata -> 'gender_identity'
        ELSE NULL
      END,
      'bdsm_roles', CASE
        WHEN COALESCE(p.metadata -> 'visibility' ->> 'bdsm_roles', 'public') = 'public'
        THEN p.metadata -> 'bdsm_roles'
        ELSE NULL
      END
    )),
    p.reputation_score
  FROM public.profiles AS p
  WHERE p.id = target_profile_id
    AND (SELECT auth.uid()) IS NOT NULL
    AND COALESCE((SELECT auth.jwt() -> 'app_metadata' ->> 'role'), '') = 'admin';
$$;

REVOKE ALL ON FUNCTION public.get_public_profile(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_public_profile(UUID) TO authenticated;
