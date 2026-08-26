-- Migration: Series Course Feature (Event Series)
-- Description: Add event_series, event_series_membership, and event_series_registrations tables
-- Created: 2026-08-26
-- Related Spec: features/events/011-event-series-spec.md

-- ============================================================
-- Part 1: Create event_series table
-- ============================================================

CREATE TABLE IF NOT EXISTS public.event_series (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  is_whole_series_required BOOLEAN NOT NULL DEFAULT FALSE,
  display_order INT NOT NULL DEFAULT 0,
  lifecycle_status TEXT NOT NULL DEFAULT 'draft'
    CHECK (lifecycle_status IN ('draft', 'published', 'archived', 'cancelled')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

-- Indexes for event_series
CREATE INDEX IF NOT EXISTS idx_event_series_creator 
  ON public.event_series(creator_id);

CREATE INDEX IF NOT EXISTS idx_event_series_lifecycle 
  ON public.event_series(lifecycle_status) 
  WHERE lifecycle_status != 'draft';

-- Shared updated_at trigger function (idempotent; schema spec requires it)
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = timezone('utc', now());
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_event_series_updated_at ON public.event_series;
CREATE TRIGGER trg_event_series_updated_at
  BEFORE UPDATE ON public.event_series
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- Part 2: Create event_series_membership table
-- ============================================================

CREATE TABLE IF NOT EXISTS public.event_series_membership (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  series_id UUID NOT NULL REFERENCES public.event_series(id) ON DELETE CASCADE,
  event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  position INT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  
  UNIQUE(series_id, event_id),
  UNIQUE(series_id, position)
);

-- Index to ensure each event belongs to at most one series
CREATE UNIQUE INDEX IF NOT EXISTS idx_event_series_membership_event 
  ON public.event_series_membership(event_id) 
  WHERE series_id IS NOT NULL;

-- ============================================================
-- Part 3: Add series_member_position column to events
-- ============================================================

ALTER TABLE public.events
ADD COLUMN IF NOT EXISTS series_member_position INT;

-- Update existing events that have series_id pointing to them as parent
UPDATE public.events e
SET series_member_position = m.position
FROM public.event_series_membership m
WHERE m.event_id = e.id;

-- Add constraint to ensure consistency
ALTER TABLE public.events
ADD CONSTRAINT events_series_member_position_check
  CHECK (series_member_position IS NULL OR series_member_position > 0);

-- ============================================================
-- Part 4: Create event_series_registrations table
-- ============================================================

CREATE TABLE IF NOT EXISTS public.event_series_registrations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  series_id UUID NOT NULL REFERENCES public.event_series(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected', 'waitlisted', 'cancelled')),
  whole_series_registration BOOLEAN NOT NULL DEFAULT FALSE,
  
  reviewed_by UUID REFERENCES public.profiles(id),
  reviewed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  
  UNIQUE(series_id, profile_id, whole_series_registration)
);

-- Indexes for event_series_registrations
CREATE INDEX IF NOT EXISTS idx_event_series_registrations_series 
  ON public.event_series_registrations(series_id);

CREATE INDEX IF NOT EXISTS idx_event_series_registrations_profile 
  ON public.event_series_registrations(profile_id);

CREATE INDEX IF NOT EXISTS idx_event_series_registrations_status 
  ON public.event_series_registrations(series_id, status);

-- Trigger for updated_at
DROP TRIGGER IF EXISTS trg_event_series_registrations_updated_at ON public.event_series_registrations;
CREATE TRIGGER trg_event_series_registrations_updated_at
  BEFORE UPDATE ON public.event_series_registrations
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- Part 5: Create get_event_series_capacity RPC (optional)
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_event_series_capacity(p_series_id UUID)
RETURNS TABLE (
  approved_series_count BIGINT,
  total_individual_slots BIGINT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    COUNT(DISTINCT CASE WHEN esr.whole_series_registration = TRUE AND esr.status IN ('approved', 'pending') THEN esr.profile_id END)::BIGINT,
    (
      SELECT COALESCE(SUM(e.max_capacity::BIGINT - COALESCE((
        SELECT COUNT(*) FROM public.event_registrations er2
        WHERE er2.event_id = e.id AND er2.status IN ('approved', 'pending', 'waitlisted')
      ), 0)), 0)::BIGINT
      FROM public.events e
      JOIN public.event_series_membership em ON e.id = em.event_id
      WHERE em.series_id = p_series_id
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute to authenticated users only
REVOKE ALL ON FUNCTION public.get_event_series_capacity(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_series_capacity(UUID) TO authenticated;

-- ============================================================
-- Part 6: Enable RLS on new tables
-- ============================================================

-- Enable RLS on event_series
ALTER TABLE public.event_series ENABLE ROW LEVEL SECURITY;

-- Membership rows are exposed through the Data API and must be protected too.
ALTER TABLE public.event_series_membership ENABLE ROW LEVEL SECURITY;

-- RLS policies for event_series
-- Users can read their own series
DROP POLICY IF EXISTS event_series_owner_read ON public.event_series;
CREATE POLICY event_series_owner_read 
  ON public.event_series 
  FOR SELECT 
  TO authenticated
  USING (creator_id = auth.uid());

-- Public can read published series
DROP POLICY IF EXISTS event_series_public_read ON public.event_series;
CREATE POLICY event_series_public_read 
  ON public.event_series 
  FOR SELECT 
  TO anon
  USING (
    lifecycle_status = 'published' 
    AND creator_id IN (SELECT id FROM public.profiles)
  );

DROP POLICY IF EXISTS event_series_public_read_authenticated ON public.event_series;
CREATE POLICY event_series_public_read_authenticated
  ON public.event_series
  FOR SELECT
  TO authenticated
  USING (lifecycle_status = 'published');

-- Only owners can insert/update their series
DROP POLICY IF EXISTS event_series_owner_insert ON public.event_series;
CREATE POLICY event_series_owner_insert 
  ON public.event_series 
  FOR INSERT 
  TO authenticated
  WITH CHECK (creator_id = auth.uid());

DROP POLICY IF EXISTS event_series_owner_update ON public.event_series;
CREATE POLICY event_series_owner_update 
  ON public.event_series 
  FOR UPDATE 
  TO authenticated
  USING (creator_id = auth.uid())
  WITH CHECK (creator_id = auth.uid());

-- RLS policies for event_series_membership
DROP POLICY IF EXISTS event_series_membership_select ON public.event_series_membership;
CREATE POLICY event_series_membership_select 
  ON public.event_series_membership 
  FOR SELECT 
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.events e 
      WHERE e.id = event_id 
      AND e.publication_status = 'published'
    )
  );

DROP POLICY IF EXISTS event_series_membership_owner_read ON public.event_series_membership;
CREATE POLICY event_series_membership_owner_read
  ON public.event_series_membership
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.event_series es
      WHERE es.id = series_id
      AND es.creator_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS event_series_membership_insert ON public.event_series_membership;
CREATE POLICY event_series_membership_insert 
  ON public.event_series_membership 
  FOR INSERT 
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.event_series es
      WHERE es.id = series_id 
      AND es.creator_id = auth.uid()
    )
    AND EXISTS (
      SELECT 1 FROM public.events e
      WHERE e.id = event_id
      AND e.creator_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS event_series_membership_update ON public.event_series_membership;
CREATE POLICY event_series_membership_update
  ON public.event_series_membership
  FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.event_series es
      WHERE es.id = series_id
      AND es.creator_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.event_series es
      WHERE es.id = series_id
      AND es.creator_id = auth.uid()
    )
    AND EXISTS (
      SELECT 1 FROM public.events e
      WHERE e.id = event_id
      AND e.creator_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS event_series_membership_delete ON public.event_series_membership;
CREATE POLICY event_series_membership_delete
  ON public.event_series_membership
  FOR DELETE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.event_series es
      WHERE es.id = series_id
      AND es.creator_id = auth.uid()
    )
  );

-- RLS policies for event_series_registrations
ALTER TABLE public.event_series_registrations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS event_series_reg_user_read ON public.event_series_registrations;
CREATE POLICY event_series_reg_user_read 
  ON public.event_series_registrations 
  FOR SELECT 
  TO authenticated
  USING (profile_id = auth.uid());

DROP POLICY IF EXISTS event_series_reg_host_read ON public.event_series_registrations;
CREATE POLICY event_series_reg_host_read 
  ON public.event_series_registrations 
  FOR SELECT 
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.event_series es
      WHERE es.id = series_id 
      AND es.creator_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS event_series_reg_anon_deny ON public.event_series_registrations;
CREATE POLICY event_series_reg_anon_deny 
  ON public.event_series_registrations 
  FOR SELECT 
  TO anon 
  USING (false);

-- ============================================================
-- Part 7: Summary
-- ============================================================

-- This migration adds complete support for Event Series (系列課程):
-- 1. event_series table - main series metadata
-- 2. event_series_membership table - links events to series
-- 3. events.series_member_position column - quick reference to series position
-- 4. event_series_registrations table - track series-level registrations
-- 5. get_event_series_capacity function - query capacity statistics
-- 6. RLS policies - secure access control

-- Future work:
-- - Edge Functions for create-event-series, add-event-to-series, etc.
-- - Frontend components for series management
-- - Integration with existing event registration flow
