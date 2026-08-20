-- Migration: 20260821000000_add_event_external_guests.sql
-- 1. 建立 event_external_guests 表，儲存主辦人手動新增的外部參與者
-- 2. 新增 RLS 政策（主辦人完全控管，admin 可讀）
-- 3. 新增 promote_waitlist_on_external_guest_delete trigger
-- 4. 修改 promote_waitlist_on_cancel() 納入外部貴賓計數
-- 5. 新增 check-in trigger 檢查

-- ============================================================
-- Step 1: Create event_external_guests table
-- ============================================================
CREATE TABLE IF NOT EXISTS public.event_external_guests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  guest_name TEXT NOT NULL,
  contact_info TEXT,
  count_towards_capacity BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

COMMENT ON TABLE public.event_external_guests IS '主辦人手動新增的外部參與者，包含無平台帳號的離線貴賓。count_towards_capacity 控制是否計入公開容量。';
COMMENT ON COLUMN public.event_external_guests.guest_name IS '主辦人輸入的辨識名稱，例如「王小明 (VIP)」';
COMMENT ON COLUMN public.event_external_guests.contact_info IS '選填聯絡方式';
COMMENT ON COLUMN public.event_external_guests.count_towards_capacity IS '是否計入活動 max_capacity：TRUE 時與 approved registrations 合計；FALSE 時不計入，僅為主辦人內部管理';

-- ============================================================
-- Step 2: RLS policies
-- ============================================================
ALTER TABLE public.event_external_guests ENABLE ROW LEVEL SECURITY;

-- SELECT: event host + admin (all columns including contact_info)
CREATE POLICY external_guests_select_host_admin
  ON public.event_external_guests
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.events e
      WHERE e.id = event_id AND e.creator_id = auth.uid()
    )
    OR auth.jwt() ->> 'role' = 'admin'
  );

-- INSERT: event host only
CREATE POLICY external_guests_insert_host
  ON public.event_external_guests
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.events e
      WHERE e.id = event_id AND e.creator_id = auth.uid()
    )
  );

-- UPDATE: event host only
CREATE POLICY external_guests_update_host
  ON public.event_external_guests
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.events e
      WHERE e.id = event_id AND e.creator_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.events e
      WHERE e.id = event_id AND e.creator_id = auth.uid()
    )
  );

-- DELETE: event host only
CREATE POLICY external_guests_delete_host
  ON public.event_external_guests
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.events e
      WHERE e.id = event_id AND e.creator_id = auth.uid()
    )
  );

-- ============================================================
-- Step 3: Update promote_waitlist_on_cancel() to account for
--          external guests that count toward capacity
-- ============================================================
CREATE OR REPLACE FUNCTION promote_waitlist_on_cancel()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  next_waitlist RECORD;
  current_approved_count INT;
  current_external_count INT;
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

  SELECT COUNT(*) INTO current_external_count
  FROM event_external_guests
  WHERE event_id = OLD.event_id AND count_towards_capacity = TRUE;

  SELECT * INTO next_waitlist
  FROM event_registrations
  WHERE event_id = OLD.event_id
    AND status = 'waitlisted'
  ORDER BY created_at ASC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF event_max_cap IS NOT NULL AND (current_approved_count + current_external_count) >= event_max_cap THEN
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
-- Step 4: Add waitlist promotion trigger for external guest
--          deletion (only when count_towards_capacity = TRUE)
-- ============================================================
CREATE OR REPLACE FUNCTION promote_waitlist_on_external_guest_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  next_waitlist RECORD;
  current_approved_count INT;
  current_external_count INT;
  event_max_cap INT;
BEGIN
  -- Only promote when the deleted guest was counted toward capacity
  IF OLD.count_towards_capacity = FALSE THEN
    RETURN OLD;
  END IF;

  SELECT max_capacity INTO event_max_cap
  FROM events WHERE id = OLD.event_id;

  IF event_max_cap IS NULL THEN
    RETURN OLD;
  END IF;

  SELECT COUNT(*) INTO current_approved_count
  FROM event_registrations
  WHERE event_id = OLD.event_id AND status = 'approved';

  SELECT COUNT(*) INTO current_external_count
  FROM event_external_guests
  WHERE event_id = OLD.event_id AND count_towards_capacity = TRUE;

  IF (current_approved_count + current_external_count) >= event_max_cap THEN
    RETURN OLD;
  END IF;

  SELECT * INTO next_waitlist
  FROM event_registrations
  WHERE event_id = OLD.event_id
    AND status = 'waitlisted'
  ORDER BY created_at ASC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN OLD;
  END IF;

  UPDATE event_registrations
  SET status = 'pending',
      waitlist_position = NULL,
      waitlist_converted_at = TIMEZONE('utc', NOW())
  WHERE id = next_waitlist.id;

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_promote_waitlist_external_guest ON event_external_guests;
CREATE TRIGGER trg_promote_waitlist_external_guest
  AFTER DELETE ON event_external_guests
  FOR EACH ROW
  EXECUTE FUNCTION promote_waitlist_on_external_guest_delete();

-- ============================================================
-- Step 5: Index
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_event_external_guests_event_id
  ON public.event_external_guests (event_id);