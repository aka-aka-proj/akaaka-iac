-- Migration: Add category, registration_form_config, recurrence_rule, series_id to events
-- Create event_registration_responses table with RLS isolation
-- Date: 2026-08-03

-- 1. Add new columns to events table
ALTER TABLE events
  ADD COLUMN IF NOT EXISTS category TEXT NOT NULL DEFAULT 'Social'
    CHECK (category IN ('Social', 'Practice')),
  ADD COLUMN IF NOT EXISTS registration_form_config JSONB DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS recurrence_rule JSONB DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS series_id UUID DEFAULT NULL;

-- 2. Create event_registration_responses table for RLS-isolated form responses
CREATE TABLE IF NOT EXISTS event_registration_responses (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  registration_id UUID NOT NULL REFERENCES event_registrations(id) ON DELETE CASCADE,
  responses JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW()),
  UNIQUE (registration_id)
);

-- 3. Enable RLS on new table
ALTER TABLE event_registration_responses ENABLE ROW LEVEL SECURITY;

-- 4. RLS for event_registration_responses:
--    SELECT: only the registrant, event host, or admin
CREATE POLICY reg_responses_read_self_host_admin ON event_registration_responses FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM event_registrations er
    WHERE er.id = registration_id
      AND (
        er.profile_id = auth.uid()
        OR EXISTS (
          SELECT 1 FROM events e
          WHERE e.id = er.event_id AND e.creator_id = auth.uid()
        )
      )
  )
  OR auth.jwt() ->> 'role' = 'admin'
);

--    INSERT: only via service role (Edge Functions bypass RLS)
CREATE POLICY reg_responses_service_insert ON event_registration_responses FOR INSERT TO authenticated
WITH CHECK (auth.jwt() ->> 'role' = 'service_role');

--    UPDATE: only via service role
CREATE POLICY reg_responses_service_update ON event_registration_responses FOR UPDATE TO authenticated
USING (auth.jwt() ->> 'role' = 'service_role')
WITH CHECK (auth.jwt() ->> 'role' = 'service_role');

-- 5. New indexes for category filtering and series lookups
CREATE INDEX IF NOT EXISTS idx_events_category ON events (category);
CREATE INDEX IF NOT EXISTS idx_events_series_id ON events (series_id) WHERE series_id IS NOT NULL;