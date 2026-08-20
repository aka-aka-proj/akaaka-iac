-- Migration: 20260822000000_add_event_invitations.sql
-- 1. 建立 event_invitations 表，儲存主辦人對已註冊平台會員的活動邀請
-- 2. 新增 RLS 政策（host/target 讀取，host 建立/撤回，target 接受/拒絕）
-- 3. 新增 block guard BEFORE INSERT trigger
-- 4. 新增 notification AFTER INSERT trigger
-- 5. 更新 notifications 表 CHECK constraint 支援 event_invitation 類型

-- ============================================================
-- Step 1: Create event_invitations table
-- ============================================================
CREATE TABLE IF NOT EXISTS public.event_invitations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
    host_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    target_profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'pending'
        CONSTRAINT event_invitations_status_check CHECK (status IN ('pending', 'accepted', 'declined', 'retracted')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    CONSTRAINT unique_active_invitation UNIQUE (event_id, target_profile_id, status)
);

COMMENT ON TABLE public.event_invitations IS '主辦人對已註冊平台會員發出的活動邀請。採非對稱授權邀請流：主辦人寫入邀請記錄後，受邀者自主接受（RSVP）以建立正式報名。';
COMMENT ON COLUMN public.event_invitations.host_id IS '發起邀請的主辦人，須與 events.creator_id 一致';
COMMENT ON COLUMN public.event_invitations.target_profile_id IS '受邀的目標會員';
COMMENT ON COLUMN public.event_invitations.status IS 'pending: 等待回覆, accepted: 已接受(已報名), declined: 已拒絕, retracted: 主辦人已撤回';

-- ============================================================
-- Step 2: RLS policies
-- ============================================================
ALTER TABLE public.event_invitations ENABLE ROW LEVEL SECURITY;

-- SELECT: host or target can read
CREATE POLICY event_invitations_select_participant
  ON public.event_invitations
  FOR SELECT TO authenticated
  USING (
    auth.uid() = host_id
    OR auth.uid() = target_profile_id
  );

-- INSERT: host only, must be the event creator
CREATE POLICY event_invitations_insert_host
  ON public.event_invitations
  FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = host_id
    AND auth.uid() = (SELECT creator_id FROM public.events WHERE id = event_id)
  );

-- UPDATE:
--   - target can change pending -> accepted/declined
--   - host can change pending -> retracted
CREATE POLICY event_invitations_update_target
  ON public.event_invitations
  FOR UPDATE TO authenticated
  USING (auth.uid() = target_profile_id AND status = 'pending')
  WITH CHECK (
    auth.uid() = target_profile_id
    AND status IN ('accepted', 'declined')
  );

CREATE POLICY event_invitations_update_host
  ON public.event_invitations
  FOR UPDATE TO authenticated
  USING (auth.uid() = host_id AND status = 'pending')
  WITH CHECK (
    auth.uid() = host_id
    AND status = 'retracted'
  );

-- DELETE: deny-by-default, no delete policy needed

-- ============================================================
-- Step 3: Block guard BEFORE INSERT trigger
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_invitation_block()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.blocks
    WHERE (blocker_id = NEW.host_id AND blocked_id = NEW.target_profile_id)
       OR (blocker_id = NEW.target_profile_id AND blocked_id = NEW.host_id)
  ) THEN
    RAISE EXCEPTION 'Blocked relationship exists.';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.check_invitation_block() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_check_invitation_block ON public.event_invitations;
CREATE TRIGGER trg_check_invitation_block
  BEFORE INSERT ON public.event_invitations
  FOR EACH ROW
  EXECUTE FUNCTION public.check_invitation_block();

-- ============================================================
-- Step 4: Notification AFTER INSERT trigger
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_invited_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  event_title TEXT;
  host_name TEXT;
BEGIN
  SELECT e.title INTO event_title
  FROM public.events e WHERE e.id = NEW.event_id;

  SELECT COALESCE(p.display_name, 'A user') INTO host_name
  FROM public.profiles p WHERE p.id = NEW.host_id;

  INSERT INTO public.notifications (
    recipient_profile_id,
    notification_type,
    event_id,
    actor_profile_id,
    title
  )
  VALUES (
    NEW.target_profile_id,
    'event_invitation',
    NEW.event_id,
    NEW.host_id,
    host_name || ' invited you to ' || event_title
  );

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_invited_profile() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_notify_invited_profile ON public.event_invitations;
CREATE TRIGGER trg_notify_invited_profile
  AFTER INSERT ON public.event_invitations
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_invited_profile();

-- ============================================================
-- Step 5: Update notifications CHECK constraints
--          to support event_invitation type
-- ============================================================
ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_notification_type_check,
  DROP CONSTRAINT IF EXISTS notifications_one_target;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_notification_type_check
    CHECK (notification_type IN ('new_event', 'new_issue', 'new_follow', 'venue_application', 'event_invitation'));

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_one_target
    CHECK (
      num_nonnulls(event_id, issue_id, actor_profile_id, venue_application_profile_id) = 1
      OR (notification_type = 'event_invitation' AND event_id IS NOT NULL AND actor_profile_id IS NOT NULL
          AND issue_id IS NULL AND venue_application_profile_id IS NULL)
    );

-- Add unique index for event_invitation notifications (one per recipient/event/host)
CREATE UNIQUE INDEX IF NOT EXISTS notifications_invitation_target_unique
  ON public.notifications (recipient_profile_id, notification_type, event_id, actor_profile_id)
  WHERE notification_type = 'event_invitation'
    AND event_id IS NOT NULL
    AND actor_profile_id IS NOT NULL;

-- ============================================================
-- Step 6: Indexes
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_event_invitations_event_id
  ON public.event_invitations (event_id);
CREATE INDEX IF NOT EXISTS idx_event_invitations_target_profile_id
  ON public.event_invitations (target_profile_id);
CREATE INDEX IF NOT EXISTS idx_event_invitations_host_id
  ON public.event_invitations (host_id);
CREATE INDEX IF NOT EXISTS idx_event_invitations_status
  ON public.event_invitations (event_id, status);