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
  WITH relationship AS (
    SELECT
      EXISTS (
        SELECT 1
        FROM public.user_follows AS outgoing
        JOIN public.user_follows AS incoming
          ON incoming.follower_id = outgoing.followed_id
         AND incoming.followed_id = outgoing.follower_id
        WHERE outgoing.follower_id = (SELECT auth.uid())
          AND outgoing.followed_id = target_profile_id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.blocks AS blocked
        WHERE (blocked.blocker_id = (SELECT auth.uid()) AND blocked.blocked_id = target_profile_id)
           OR (blocked.blocker_id = target_profile_id AND blocked.blocked_id = (SELECT auth.uid()))
      ) AS can_view_x
  )
  SELECT
    p.id,
    p.role_status,
    p.display_name,
    p.bio,
    CASE
      WHEN p.id = (SELECT auth.uid()) OR relationship.can_view_x THEN p.external_social_links
      ELSE COALESCE((
        SELECT jsonb_agg(link)
        FROM jsonb_array_elements(p.external_social_links) AS link
        WHERE link ->> 'platform' <> 'x'
      ), '[]'::jsonb)
    END,
    p.metadata,
    p.reputation_score,
    EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p.external_social_links) AS link
      WHERE link ->> 'platform' = 'x'
        AND NULLIF(link ->> 'url', '') IS NOT NULL
    )
  FROM public.profiles AS p
  CROSS JOIN relationship
  WHERE p.id = target_profile_id
    AND (SELECT auth.uid()) IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.get_profile_for_viewer(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_profile_for_viewer(UUID) TO authenticated;
