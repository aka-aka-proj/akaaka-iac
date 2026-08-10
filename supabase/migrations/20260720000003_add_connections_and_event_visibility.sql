-- Connections table & Event Visibility RLS
-- Adds connections table for bidirectional relationships,
-- replaces events_read_all with visibility-based policy.

-- 1) Create connections table
CREATE TABLE IF NOT EXISTS connections (
  requester_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  receiver_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW()),
  PRIMARY KEY (requester_id, receiver_id),
  CHECK (requester_id <> receiver_id)
);

-- 2) RLS for connections
ALTER TABLE connections ENABLE ROW LEVEL SECURITY;

CREATE POLICY connections_read_self ON connections FOR SELECT TO authenticated
USING (requester_id = auth.uid() OR receiver_id = auth.uid());

CREATE POLICY connections_insert_requester ON connections FOR INSERT TO authenticated
WITH CHECK (requester_id = auth.uid());

CREATE POLICY connections_update_receiver ON connections FOR UPDATE TO authenticated
USING (receiver_id = auth.uid()) WITH CHECK (receiver_id = auth.uid());

CREATE POLICY connections_delete_participant ON connections FOR DELETE TO authenticated
USING (requester_id = auth.uid() OR receiver_id = auth.uid());

-- 3) Replace events_read_all with visibility-based policy
DROP POLICY IF EXISTS events_read_all ON events;

CREATE POLICY events_read_visibility ON events FOR SELECT TO authenticated
USING (
  -- public: all authenticated users can see
  (visibility_settings ->> 'type') IS NULL
  OR (visibility_settings ->> 'type') = 'public'
  -- owner can always see own events
  OR creator_id = auth.uid()
  -- connections_only: viewer and creator have an accepted connection
  OR (
    (visibility_settings ->> 'type') = 'connections_only'
    AND EXISTS (
      SELECT 1 FROM connections c
      WHERE c.status = 'accepted'
        AND (
          (c.requester_id = auth.uid() AND c.receiver_id = events.creator_id)
          OR
          (c.requester_id = events.creator_id AND c.receiver_id = auth.uid())
        )
    )
  )
);

-- 4) Indexes
CREATE INDEX IF NOT EXISTS idx_connections_receiver_id ON connections (receiver_id);
CREATE INDEX IF NOT EXISTS idx_connections_requester_id ON connections (requester_id);
