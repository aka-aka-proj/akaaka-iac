-- Migration: 20260829120000_add_event_share_token.sql
-- 私人活動分享連結（ADR-022；依 agent 安全審查修訂為獨立表設計）
-- 1. 建立 event_share_tokens 表：RLS 啟用且無 policy（deny-by-default）、
--    撤銷一般角色全部 table privilege——token 不得存於 events 欄位，
--    因 row-level 授權無法阻止可讀取事件列的角色讀出 bearer credential
-- 2. ensure/rotate 管理 RPC：creator-only 且要求活動目前為 private
-- 3. get_event_by_share_token：持 token 者對已發布私人活動的唯讀存取
-- 4. hygiene trigger：活動離開 private 狀態時刪除 token 列

-- ============================================================
-- Step 1: Token table — direct access fully denied
-- ============================================================
CREATE TABLE IF NOT EXISTS public.event_share_tokens (
    event_id UUID PRIMARY KEY REFERENCES public.events(id) ON DELETE CASCADE,
    token TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

COMMENT ON TABLE public.event_share_tokens IS
  '私人活動分享連結 bearer credential（ADR-022）；僅可經 share token RPC 讀寫，對所有直接讀取路徑不可見。';

ALTER TABLE public.event_share_tokens ENABLE ROW LEVEL SECURITY;

-- 無任何 policy：RLS deny-by-default。table privilege 一併撤銷，
-- 使 service-role 以外的任何直接 Data API 存取都失敗。
REVOKE ALL ON public.event_share_tokens FROM anon, authenticated;

-- ============================================================
-- Step 2: Owner-side token management RPCs
-- 審查 P1 修復：非 private 活動上一律拒絕產生／輪替，防止 token
-- 在公開狀態下被建立後於轉回 private 時殘留有效。
-- ============================================================
CREATE OR REPLACE FUNCTION public.ensure_event_share_token(p_event_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_is_shareable BOOLEAN;
BEGIN
  -- Row lock serializes against concurrent visibility/publication updates:
  -- re-evaluated after any conflicting transaction commits, so a token can
  -- never be minted for an event that just left the published+private state.
  SELECT e.creator_id = auth.uid()
     AND COALESCE(e.visibility_settings ->> 'type', 'public') = 'private'
    INTO v_is_shareable
  FROM public.events e
  WHERE e.id = p_event_id
  FOR UPDATE;

  IF NOT v_is_shareable THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.event_share_tokens (event_id, token)
  VALUES (p_event_id, encode(gen_random_bytes(24), 'hex'))
  ON CONFLICT (event_id) DO NOTHING;

  RETURN (
    SELECT est.token
    FROM public.event_share_tokens est
    WHERE est.event_id = p_event_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.rotate_event_share_token(p_event_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  new_token TEXT;
  v_is_shareable BOOLEAN;
BEGIN
  -- Same serialization contract as ensure_event_share_token.
  SELECT e.creator_id = auth.uid()
     AND COALESCE(e.visibility_settings ->> 'type', 'public') = 'private'
    INTO v_is_shareable
  FROM public.events e
  WHERE e.id = p_event_id
  FOR UPDATE;

  IF NOT v_is_shareable THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.event_share_tokens (event_id, token)
  VALUES (p_event_id, encode(gen_random_bytes(24), 'hex'))
  ON CONFLICT (event_id) DO UPDATE
    SET token = encode(gen_random_bytes(24), 'hex'),
        updated_at = timezone('utc', now());

  RETURN (
    SELECT est.token
    FROM public.event_share_tokens est
    WHERE est.event_id = p_event_id
  );
END;
$$;

-- ============================================================
-- Step 3: Token-based read path for published private events
-- 條件不符時一律空結果，不區分「token 錯誤」與「狀態不符」。
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_event_by_share_token(p_token TEXT)
RETURNS SETOF public.events
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT e.*
  FROM public.event_share_tokens est
  JOIN public.events e ON e.id = est.event_id
  WHERE est.token = p_token
    AND p_token IS NOT NULL
    AND e.lifecycle_status <> 'draft'
    AND e.publication_status = 'published'
    AND COALESCE(e.visibility_settings ->> 'type', 'public') = 'private'
    AND (
      (SELECT auth.uid()) IS NULL
      OR NOT EXISTS (
        SELECT 1
        FROM public.blocks b
        WHERE (b.blocker_id = (SELECT auth.uid()) AND b.blocked_id = e.creator_id)
           OR (b.blocker_id = e.creator_id AND b.blocked_id = (SELECT auth.uid()))
      )
    );
$$;

COMMENT ON FUNCTION public.get_event_by_share_token(TEXT) IS
  'Returns the published private event matching a share token (ADR-022); empty result on any mismatch. Never exposes registration, invitation, or guest data.';

-- ============================================================
-- Step 3b: Capacity aggregate for token viewers
-- 與 get_event_capacity 相同形態，改以 token gate 授權，
-- 使 token viewer 的詳情頁名額顯示一致（ADR-022）。
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_event_capacity_by_share_token(p_token TEXT)
RETURNS TABLE (
  approved_registration_count BIGINT,
  capacity_external_guest_count BIGINT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT
    (
      SELECT COUNT(*)
      FROM public.event_registrations er
      WHERE er.event_id = e.id
        AND er.status = 'approved'
    ) AS approved_registration_count,
    (
      SELECT COUNT(*)
      FROM public.event_external_guests eg
      WHERE eg.event_id = e.id
        AND eg.count_towards_capacity = TRUE
    ) AS capacity_external_guest_count
  FROM public.event_share_tokens est
  JOIN public.events e ON e.id = est.event_id
  WHERE est.token = p_token
    AND p_token IS NOT NULL
    AND e.lifecycle_status <> 'draft'
    AND e.publication_status = 'published'
    AND COALESCE(e.visibility_settings ->> 'type', 'public') = 'private'
    AND (
      (SELECT auth.uid()) IS NULL
      OR NOT EXISTS (
        SELECT 1
        FROM public.blocks b
        WHERE (b.blocker_id = (SELECT auth.uid()) AND b.blocked_id = e.creator_id)
           OR (b.blocker_id = e.creator_id AND b.blocked_id = (SELECT auth.uid()))
      )
    );
$$;

COMMENT ON FUNCTION public.get_event_capacity_by_share_token(TEXT) IS
  'Returns the same capacity aggregates as get_event_capacity for a valid private-event share token (ADR-022); counts only, never participant data.';

-- ============================================================
-- Step 4: Grants
-- ============================================================
REVOKE ALL ON FUNCTION public.ensure_event_share_token(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_event_share_token(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.rotate_event_share_token(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rotate_event_share_token(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.get_event_by_share_token(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_by_share_token(TEXT) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.get_event_capacity_by_share_token(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_capacity_by_share_token(TEXT) TO anon, authenticated;

-- ============================================================
-- Step 5: Visibility-change hygiene
-- 離開 private 即刪除 token 列；SECURITY DEFINER 以取得刪除權限
-- （表本身 deny-all）。
-- ============================================================
CREATE OR REPLACE FUNCTION public.delete_share_token_off_private()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT (
    NEW.lifecycle_status <> 'draft'
    AND NEW.publication_status = 'published'
    AND COALESCE(NEW.visibility_settings ->> 'type', 'public') = 'private'
  ) THEN
    DELETE FROM public.event_share_tokens WHERE event_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_share_token_off_private() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_delete_share_token_off_private ON public.events;
CREATE TRIGGER trg_delete_share_token_off_private
  BEFORE UPDATE OF visibility_settings, publication_status, lifecycle_status ON public.events
  FOR EACH ROW
  EXECUTE FUNCTION public.delete_share_token_off_private();
