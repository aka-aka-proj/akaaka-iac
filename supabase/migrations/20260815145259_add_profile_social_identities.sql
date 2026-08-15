-- Issue #22: persist provider ownership proof separately from user-entered URLs.
-- Provider credentials, callback allowlists, and manual linking remain hosted
-- Auth configuration and are not represented by this database migration.
CREATE TABLE IF NOT EXISTS public.profile_social_identities (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  platform TEXT NOT NULL CHECK (platform IN ('x', 'facebook')),
  provider_identity_id TEXT NOT NULL,
  provider_subject TEXT NOT NULL,
  provider_username TEXT,
  display_url TEXT,
  verified_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  UNIQUE (profile_id, platform),
  UNIQUE (platform, provider_subject),
  UNIQUE (platform, provider_identity_id)
);

ALTER TABLE public.profile_social_identities ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.profile_social_identities FROM anon;
GRANT SELECT ON TABLE public.profile_social_identities TO authenticated;
GRANT ALL ON TABLE public.profile_social_identities TO service_role;

CREATE POLICY profile_social_identities_select_owner
  ON public.profile_social_identities
  FOR SELECT
  TO authenticated
  USING (profile_id = (SELECT auth.uid()));

DROP TRIGGER IF EXISTS trg_profile_social_identities_updated_at
  ON public.profile_social_identities;
CREATE TRIGGER trg_profile_social_identities_updated_at
  BEFORE UPDATE ON public.profile_social_identities
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE INDEX IF NOT EXISTS idx_profile_social_identities_profile_id
  ON public.profile_social_identities (profile_id);
CREATE INDEX IF NOT EXISTS idx_profile_social_identities_platform_subject
  ON public.profile_social_identities (platform, provider_subject);

-- Keep the public resolver projection free of ownership keys. The existing
-- function's return type must be recreated because the verified projection is
-- a new response field.
DROP FUNCTION IF EXISTS public.get_public_profile(UUID);
CREATE FUNCTION public.get_public_profile(target_profile_id UUID)
RETURNS TABLE (
  id UUID,
  role_status TEXT,
  display_name TEXT,
  bio TEXT,
  external_social_links JSONB,
  verified_social_links JSONB,
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
    COALESCE(verified.links, '[]'::jsonb),
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
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
      jsonb_strip_nulls(jsonb_build_object(
        'platform', s.platform,
        'display_url', s.display_url,
        'provider_username', s.provider_username,
        'verified_at', s.verified_at
      )) ORDER BY s.platform
    ) AS links
    FROM public.profile_social_identities AS s
    WHERE s.profile_id = p.id
  ) AS verified ON TRUE
  WHERE p.id = target_profile_id
    AND (SELECT auth.uid()) IS NOT NULL
    AND COALESCE((SELECT auth.jwt() -> 'app_metadata' ->> 'role'), '') = 'admin';
$$;

REVOKE ALL ON FUNCTION public.get_public_profile(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_public_profile(UUID) TO authenticated;
