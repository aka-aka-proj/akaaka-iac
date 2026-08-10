-- AkaAka initial schema
-- Matches the current remote database state as of 2026-07-17

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1) profiles
CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role_status TEXT NOT NULL DEFAULT 'general'
    CHECK (role_status IN ('general', 'venue_pending', 'venue_approved')),
  display_name TEXT,
  bio TEXT,
  external_social_links JSONB NOT NULL DEFAULT '[]'::jsonb,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  venue_metadata JSONB DEFAULT NULL,
  reputation_score INT NOT NULL DEFAULT 0 CHECK (reputation_score >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW())
);

ALTER TABLE profiles
ADD CONSTRAINT profiles_social_links_min_one
CHECK (
  external_social_links IS NOT NULL
  AND jsonb_typeof(external_social_links) = 'array'
  AND jsonb_array_length(external_social_links) >= 1
);

-- 2) events
CREATE TABLE IF NOT EXISTS events (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  creator_id UUID NOT NULL REFERENCES profiles(id),
  title TEXT NOT NULL,
  description TEXT,
  event_type TEXT NOT NULL,
  is_venue_hosted BOOLEAN NOT NULL DEFAULT FALSE,
  visibility_settings JSONB NOT NULL DEFAULT '{"type":"public"}'::jsonb,
  start_time TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW())
);

-- 3) event_threads
CREATE TABLE IF NOT EXISTS event_threads (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  event_id UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL REFERENCES profiles(id),
  content TEXT NOT NULL,
  parent_id UUID REFERENCES event_threads(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW())
);

-- 4) recommendations
CREATE TABLE IF NOT EXISTS recommendations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  from_profile_id UUID NOT NULL REFERENCES profiles(id),
  to_profile_id UUID NOT NULL REFERENCES profiles(id),
  score_increment INT NOT NULL DEFAULT 1 CHECK (score_increment > 0),
  comment TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW()),
  CONSTRAINT recommendations_no_self_recommendation CHECK (from_profile_id <> to_profile_id)
);

-- 5) blocks
CREATE TABLE IF NOT EXISTS blocks (
  blocker_id UUID NOT NULL REFERENCES profiles(id),
  blocked_id UUID NOT NULL REFERENCES profiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW()),
  PRIMARY KEY (blocker_id, blocked_id),
  CHECK (blocker_id <> blocked_id)
);

-- 6) reports
CREATE TABLE IF NOT EXISTS reports (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  reporter_id UUID NOT NULL REFERENCES profiles(id),
  target_profile_id UUID REFERENCES profiles(id),
  target_event_id UUID REFERENCES events(id),
  category TEXT NOT NULL CHECK (category IN ('harassment', 'impersonation', 'spam', 'safety_risk', 'other')),
  details TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'triaging', 'resolved', 'rejected')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW()),
  resolved_at TIMESTAMPTZ
);

-- 7) moderation_actions
CREATE TABLE IF NOT EXISTS moderation_actions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  report_id UUID REFERENCES reports(id) ON DELETE SET NULL,
  admin_id UUID NOT NULL REFERENCES profiles(id),
  action_type TEXT NOT NULL CHECK (action_type IN ('warn', 'suspend', 'ban', 'role_upgrade', 'role_revoke', 'note')),
  target_profile_id UUID REFERENCES profiles(id),
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW())
);

-- 8) audit_logs
CREATE TABLE IF NOT EXISTS audit_logs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  actor_id UUID NOT NULL REFERENCES profiles(id),
  target_profile_id UUID REFERENCES profiles(id),
  action TEXT NOT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW())
);

-- 9) issues
CREATE TABLE IF NOT EXISTS issues (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  reporter_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  log_url TEXT,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'resolved', 'closed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW())
);

-- 10) issue_comments
CREATE TABLE IF NOT EXISTS issue_comments (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  issue_id UUID NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW())
);

-- RLS
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE recommendations ENABLE ROW LEVEL SECURITY;
ALTER TABLE blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE moderation_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE issues ENABLE ROW LEVEL SECURITY;
ALTER TABLE issue_comments ENABLE ROW LEVEL SECURITY;

-- profiles
CREATE POLICY profiles_read_all ON profiles FOR SELECT TO authenticated USING (true);
CREATE POLICY profiles_update_self ON profiles FOR UPDATE TO authenticated
USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

-- events
CREATE POLICY events_read_all ON events FOR SELECT TO authenticated USING (true);
CREATE POLICY events_insert_owner ON events FOR INSERT TO authenticated
WITH CHECK (
  creator_id = auth.uid()
  AND (
    is_venue_hosted = false
    OR EXISTS (
      SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.role_status = 'venue_approved'
    )
  )
);
CREATE POLICY events_update_owner ON events FOR UPDATE TO authenticated
USING (creator_id = auth.uid()) WITH CHECK (creator_id = auth.uid());

-- event_threads
CREATE POLICY threads_read_all ON event_threads FOR SELECT TO authenticated USING (true);
CREATE POLICY threads_insert_owner ON event_threads FOR INSERT TO authenticated
WITH CHECK (profile_id = auth.uid());
CREATE POLICY threads_update_owner ON event_threads FOR UPDATE TO authenticated
USING (profile_id = auth.uid()) WITH CHECK (profile_id = auth.uid());

-- recommendations
CREATE POLICY recommendations_read_all ON recommendations FOR SELECT TO authenticated USING (true);
CREATE POLICY recommendations_insert_self ON recommendations FOR INSERT TO authenticated
WITH CHECK (from_profile_id = auth.uid());

-- blocks
CREATE POLICY blocks_read_owner ON blocks FOR SELECT TO authenticated
USING (blocker_id = auth.uid());
CREATE POLICY blocks_insert_owner ON blocks FOR INSERT TO authenticated
WITH CHECK (blocker_id = auth.uid());
CREATE POLICY blocks_delete_owner ON blocks FOR DELETE TO authenticated
USING (blocker_id = auth.uid());

-- reports
CREATE POLICY reports_insert_owner ON reports FOR INSERT TO authenticated
WITH CHECK (reporter_id = auth.uid());
CREATE POLICY reports_read_owner ON reports FOR SELECT TO authenticated
USING (reporter_id = auth.uid() OR auth.jwt() ->> 'role' = 'admin');

-- moderation_actions
CREATE POLICY moderation_actions_admin_rw ON moderation_actions FOR ALL TO authenticated
USING (auth.jwt() ->> 'role' = 'admin')
WITH CHECK (auth.jwt() ->> 'role' = 'admin');

-- audit_logs
CREATE POLICY audit_logs_admin_read ON audit_logs FOR SELECT TO authenticated
USING (auth.jwt() ->> 'role' = 'admin');
CREATE POLICY audit_logs_system_insert ON audit_logs FOR INSERT TO authenticated
WITH CHECK (auth.jwt() ->> 'role' = 'admin');

-- issues
CREATE POLICY issues_insert_owner ON issues FOR INSERT TO authenticated
WITH CHECK (reporter_id = auth.uid());
CREATE POLICY issues_read_owner ON issues FOR SELECT TO authenticated
USING (reporter_id = auth.uid() OR auth.jwt() ->> 'role' = 'admin');
CREATE POLICY issues_update_admin ON issues FOR UPDATE TO authenticated
USING (auth.jwt() ->> 'role' = 'admin')
WITH CHECK (auth.jwt() ->> 'role' = 'admin');

-- issue_comments
CREATE POLICY issue_comments_insert_auth ON issue_comments FOR INSERT TO authenticated
WITH CHECK (profile_id = auth.uid());
CREATE POLICY issue_comments_read_members ON issue_comments FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM issues i
    WHERE i.id = issue_id
      AND (i.reporter_id = auth.uid() OR auth.jwt() ->> 'role' = 'admin')
  )
);

-- Triggers
CREATE OR REPLACE FUNCTION apply_recommendation_score()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  weight NUMERIC := 1.0;
BEGIN
  IF EXISTS (
    SELECT 1 FROM profiles p
    WHERE p.id = NEW.from_profile_id
      AND p.role_status = 'venue_approved'
  ) THEN
    weight := 1.5;
  END IF;

  UPDATE profiles
  SET reputation_score = reputation_score + CEIL(NEW.score_increment * weight)::INT
  WHERE id = NEW.to_profile_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_apply_recommendation_score ON recommendations;
CREATE TRIGGER trg_apply_recommendation_score
AFTER INSERT ON recommendations
FOR EACH ROW
EXECUTE FUNCTION apply_recommendation_score();

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = TIMEZONE('utc', NOW());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_issues_updated_at ON issues;
CREATE TRIGGER trg_issues_updated_at
BEFORE UPDATE ON issues
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

-- Indexes
CREATE INDEX IF NOT EXISTS idx_profiles_metadata_gin ON profiles USING GIN (metadata);
CREATE INDEX IF NOT EXISTS idx_profiles_social_links_gin ON profiles USING GIN (external_social_links);
CREATE INDEX IF NOT EXISTS idx_events_visibility_gin ON events USING GIN (visibility_settings);
CREATE INDEX IF NOT EXISTS idx_reports_status_created_at ON reports (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_issues_status_created_at ON issues (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_issues_reporter_id ON issues (reporter_id);
CREATE INDEX IF NOT EXISTS idx_issue_comments_issue_id ON issue_comments (issue_id);
