-- Migration: 20260829120000_add_event_share_token.sql
-- 私人活動分享連結（ADR-022）
-- 1. 新增 events.share_token 欄位與 partial unique index
-- 2. 收緊欄位權限：一般角色不得直接 UPDATE share_token（僅能經受控 RPC）
-- 3. ensure_event_share_token / rotate_event_share_token：creator-only token 管理
-- 4. get_event_by_share_token：持 token 者對已發布私人活動的唯讀存取
-- 5. BEFORE WRITE trigger：活動離開 private 狀態時自動清除 token

-- ============================================================
-- Step 1: Column + index
-- ============================================================
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS share_token TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_events_share_token
  ON public.events (share_token)
  WHERE share_token IS NOT NULL;

COMMENT ON COLUMN public.events.share_token IS
  '私人活動分享連結憑證（ADR-022）；48 hex chars，僅經 share token RPC 管理。';

-- ============================================================
-- Step 2: Column privilege hardening
-- Postgres 語意：table-level UPDATE grant 存在時，column-level REVOKE
-- 不生效。因此撤銷 table-level 後「逐欄重新授與、排除 share_token」，
-- 使一般角色無法直接寫入 token（僅能經 SECURITY DEFINER RPC）。
--
-- ⚠️ INVARIANT：未來任何為 events 新增欄位的 migration，必須同步把
-- 該欄位加入下方 GRANT UPDATE 清單，否則主辦人將無法更新該欄位。
-- ============================================================
REVOKE UPDATE ON public.events FROM authenticated;

GRANT UPDATE (
  id,
  creator_id,
  title,
  description,
  category,
  event_type,
  lifecycle_status,
  publication_status,
  publish_at,
  unpublish_at,
  is_venue_hosted,
  attendance_fee_type,
  attendance_fee_amount,
  visibility_settings,
  registration_form_config,
  recurrence_rule,
  series_id,
  start_time,
  location_region,
  location_detail,
  max_capacity,
  registration_deadline,
  external_registration_url,
  source_url,
  creator_display_name,
  creator_avatar_path,
  created_at,
  updated_at
) ON public.events TO authenticated;

-- ============================================================
-- Step 3: Owner-side token management RPCs
-- ============================================================
CREATE OR REPLACE FUNCTION public.ensure_event_share_token(p_event_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_uid UUID := auth.uid();
  current_token TEXT;
BEGIN
  SELECT share_token INTO current_token
  FROM public.events
  WHERE id = p_event_id AND creator_id = v_uid;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF current_token IS NOT NULL THEN
    RETURN current_token;
  END IF;

  -- 冪等產生；併發下 WHERE share_token IS NULL 保證僅一方寫入成功，
  -- 最後重新讀取回傳勝出值。
  UPDATE public.events
  SET share_token = encode(gen_random_bytes(24), 'hex')
  WHERE id = p_event_id
    AND creator_id = v_uid
    AND share_token IS NULL;

  RETURN (SELECT share_token FROM public.events WHERE id = p_event_id);
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
BEGIN
  UPDATE public.events
  SET share_token = encode(gen_random_bytes(24), 'hex')
  WHERE id = p_event_id AND creator_id = auth.uid()
  RETURNING share_token INTO new_token;

  -- 非 owner 或活動不存在時回傳 NULL，不洩漏存在性差異。
  RETURN new_token;
END;
$$;

-- ============================================================
-- Step 4: Token-based read path for published private events
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_event_by_share_token(p_token TEXT)
RETURNS SETOF public.events
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT e.*
  FROM public.events e
  WHERE e.share_token = p_token
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
-- Step 5: Grants
-- ============================================================
REVOKE ALL ON FUNCTION public.ensure_event_share_token(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_event_share_token(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.rotate_event_share_token(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rotate_event_share_token(UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.get_event_by_share_token(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_by_share_token(TEXT) TO anon, authenticated;

-- ============================================================
-- Step 6: Visibility-change hygiene
-- token 只允許存在於 private 活動上；一旦離開 private 立即失效，
-- 防止「先設 token、轉公開被旁觀者讀走、再轉回 private」的重用漏洞。
-- ============================================================
CREATE OR REPLACE FUNCTION public.clear_share_token_off_private()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF COALESCE(NEW.visibility_settings ->> 'type', 'public') IS DISTINCT FROM 'private'
     AND NEW.share_token IS NOT NULL THEN
    NEW.share_token := NULL;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.clear_share_token_off_private() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_clear_share_token_off_private ON public.events;
CREATE TRIGGER trg_clear_share_token_off_private
  BEFORE UPDATE OF visibility_settings ON public.events
  FOR EACH ROW
  EXECUTE FUNCTION public.clear_share_token_off_private();
