-- Return profile data through an authenticated, viewer-aware projection.
-- X URLs are withheld unless the viewer owns the profile or the pair is
-- mutually following and neither side has blocked the other. A boolean keeps
-- the UI able to explain that a link exists without disclosing its URL.
CREATE OR REPLACE FUNCTION public.get_profile_for_viewer(target_profile_id UUID)
RETURNS TABLE (
  id UUID,
  role_status TEXT,
  display_name TEXT,
  bio TEXT,
  external_social_links JSONB,
  metadata JSONB,
  reputation_score INTEGER,
  x_link_provided BOOLEAN
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH viewer AS (
    SELECT
      (SELECT auth.uid()) AS viewer_id,
      COALESCE((SELECT auth.jwt() -> 'app_metadata' ->> 'role'), '') = 'admin' AS is_admin
  ),
  relationship AS (
    SELECT
      EXISTS (
        SELECT 1
        FROM public.user_follows AS outgoing
        JOIN public.user_follows AS incoming
          ON incoming.follower_id = outgoing.followed_id
         AND incoming.followed_id = outgoing.follower_id
        WHERE outgoing.follower_id = (SELECT viewer_id FROM viewer)
          AND outgoing.followed_id = target_profile_id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.blocks AS blocked
        WHERE (blocked.blocker_id = (SELECT viewer_id FROM viewer) AND blocked.blocked_id = target_profile_id)
           OR (blocked.blocker_id = target_profile_id AND blocked.blocked_id = (SELECT viewer_id FROM viewer))
      ) AS can_view_x
  )
  SELECT
    p.id,
    p.role_status,
    p.display_name,
    CASE
      WHEN viewer.is_admin AND p.id <> viewer.viewer_id
      THEN CASE
        WHEN COALESCE(p.metadata -> 'visibility' ->> 'bio', 'public') = 'public' THEN p.bio
        ELSE NULL
      END
      ELSE p.bio
    END,
    CASE
      WHEN p.id = (SELECT auth.uid()) OR relationship.can_view_x THEN p.external_social_links
      ELSE COALESCE((
        SELECT jsonb_agg(link)
        FROM jsonb_array_elements(p.external_social_links) AS link
        WHERE COALESCE(link ->> 'platform', '') <> 'x'
      ), '[]'::jsonb)
    END,
    CASE
      WHEN viewer.is_admin AND p.id <> viewer.viewer_id THEN jsonb_strip_nulls(jsonb_build_object(
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
      ))
      ELSE p.metadata
    END,
    p.reputation_score,
    EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p.external_social_links) AS link
      WHERE link ->> 'platform' = 'x'
        AND NULLIF(link ->> 'url', '') IS NOT NULL
    )
  FROM public.profiles AS p
  CROSS JOIN viewer
  CROSS JOIN relationship
  WHERE p.id = target_profile_id
    AND viewer.viewer_id IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.get_profile_for_viewer(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_profile_for_viewer(UUID) TO authenticated;
