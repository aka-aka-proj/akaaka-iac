-- Event Registration System
-- Adds event_registrations table, alters events table, adds RLS, triggers, and indexes.

-- 1) Alter events table — add capacity and deadline fields
ALTER TABLE events
  ADD COLUMN IF NOT EXISTS max_capacity INT DEFAULT NULL
    CHECK (max_capacity IS NULL OR max_capacity > 0),
  ADD COLUMN IF NOT EXISTS registration_deadline TIMESTAMPTZ DEFAULT NULL;

-- 2) Create event_registrations table
CREATE TABLE IF NOT EXISTS event_registrations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled', 'waitlisted')),
  waitlist_position INT DEFAULT NULL,
  reviewed_by UUID REFERENCES profiles(id),
  reviewed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW()),
  UNIQUE (event_id, profile_id)
);

-- 3) RLS
ALTER TABLE event_registrations ENABLE ROW LEVEL SECURITY;

-- SELECT: self + event host + admin
CREATE POLICY registrations_read_self_host_admin ON event_registrations FOR SELECT TO authenticated
USING (
  profile_id = auth.uid()
  OR EXISTS (
    SELECT 1 FROM events e
    WHERE e.id = event_id AND e.creator_id = auth.uid()
  )
  OR auth.jwt() ->> 'role' = 'admin'
);

-- INSERT: self only
CREATE POLICY registrations_insert_self ON event_registrations FOR INSERT TO authenticated
WITH CHECK (profile_id = auth.uid());

-- UPDATE: event host only (approve/reject)
CREATE POLICY registrations_update_host ON event_registrations FOR UPDATE TO authenticated
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

-- DELETE: self (cancel) + event host (force cancel)
CREATE POLICY registrations_delete_self ON event_registrations FOR DELETE TO authenticated
USING (
  profile_id = auth.uid()
  OR EXISTS (
    SELECT 1 FROM events e
    WHERE e.id = event_id AND e.creator_id = auth.uid()
  )
);

-- 4) Waitlist promotion trigger
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
      waitlist_position = NULL
  WHERE id = next_waitlist.id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_promote_waitlist ON event_registrations;
CREATE TRIGGER trg_promote_waitlist
AFTER UPDATE ON event_registrations
FOR EACH ROW
EXECUTE FUNCTION promote_waitlist_on_cancel();

-- 5) Indexes
CREATE INDEX IF NOT EXISTS idx_event_registrations_event_id ON event_registrations (event_id);
CREATE INDEX IF NOT EXISTS idx_event_registrations_profile_id ON event_registrations (profile_id);
CREATE INDEX IF NOT EXISTS idx_event_registrations_status ON event_registrations (event_id, status);
CREATE INDEX IF NOT EXISTS idx_event_registrations_waitlist ON event_registrations (event_id, created_at ASC)
  WHERE status = 'waitlisted';
