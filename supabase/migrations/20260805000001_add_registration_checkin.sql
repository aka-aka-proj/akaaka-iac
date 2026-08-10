-- Migration: 20260805000001_add_registration_checkin.sql
-- 1. 為 event_registrations 新增 checked_in_at 欄位，記錄實際出席簽到時間
-- 2. 新增 waitlist_converted_at 欄位，記錄候補轉化時間（供 get-user-analytics 統計）
-- 3. 更新 promote_waitlist_on_cancel trigger 以設定 waitlist_converted_at
-- 4. 新增主辦人簽到 RLS 政策

-- ============================================================
-- Step 1: Add checked_in_at column
-- ============================================================
ALTER TABLE event_registrations
ADD COLUMN IF NOT EXISTS checked_in_at TIMESTAMPTZ;

COMMENT ON COLUMN event_registrations.checked_in_at IS '實際出席簽到時間戳，NULL 表示尚未簽到。僅 status = approved 的報名可被簽到。';

-- ============================================================
-- Step 2: Add waitlist_converted_at column
-- ============================================================
-- 供 get-user-analytics 統計「候補轉化數」使用。
-- 當候補者被自動遞補為 pending 時，由 trigger 填入時間戳。
ALTER TABLE event_registrations
ADD COLUMN IF NOT EXISTS waitlist_converted_at TIMESTAMPTZ;

COMMENT ON COLUMN event_registrations.waitlist_converted_at IS '候補轉化時間戳。當 waitlisted 記錄被 promote 為 pending 時，由 trigger 填入。NULL 表示未曾從候補轉化。';

-- ============================================================
-- Step 3: Update promote trigger to set waitlist_converted_at
-- ============================================================
CREATE OR REPLACE FUNCTION promote_waitlist_on_cancel()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  next_waitlist RECORD;
  current_approved_count INT;
  event_max_cap INT;
BEGIN
  IF OLD.status NOT IN ('approved', 'waitlisted') OR NEW.status != 'cancelled' THEN
    RETURN NEW;
  END IF;

  SELECT max_capacity INTO event_max_cap
  FROM events WHERE id = OLD.event_id;

  SELECT COUNT(*) INTO current_approved_count
  FROM event_registrations
  WHERE event_id = OLD.event_id AND status = 'approved';

  SELECT * INTO next_waitlist
  FROM event_registrations
  WHERE event_id = OLD.event_id
    AND status = 'waitlisted'
  ORDER BY created_at ASC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF event_max_cap IS NOT NULL AND current_approved_count >= event_max_cap THEN
    RETURN NEW;
  END IF;

  UPDATE event_registrations
  SET status = 'pending',
      waitlist_position = NULL,
      waitlist_converted_at = TIMEZONE('utc', NOW())
  WHERE id = next_waitlist.id;

  RETURN NEW;
END;
$$;

-- ============================================================
-- Step 4: Add explicit check-in RLS policy for event hosts
-- ============================================================
CREATE POLICY registrations_checkin_host
  ON event_registrations
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM events e
      WHERE e.id = event_id AND e.creator_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM events e
      WHERE e.id = event_id AND e.creator_id = auth.uid()
    )
  );