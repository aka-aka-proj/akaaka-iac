-- Issues table
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

-- Issue comments table
CREATE TABLE IF NOT EXISTS issue_comments (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  issue_id UUID NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT TIMEZONE('utc', NOW())
);

-- RLS
ALTER TABLE issues ENABLE ROW LEVEL SECURITY;
ALTER TABLE issue_comments ENABLE ROW LEVEL SECURITY;

CREATE POLICY issues_insert_owner ON issues FOR INSERT TO authenticated
WITH CHECK (reporter_id = auth.uid());

CREATE POLICY issues_read_owner ON issues FOR SELECT TO authenticated
USING (reporter_id = auth.uid() OR auth.jwt() ->> 'role' = 'admin');

CREATE POLICY issues_update_admin ON issues FOR UPDATE TO authenticated
USING (auth.jwt() ->> 'role' = 'admin')
WITH CHECK (auth.jwt() ->> 'role' = 'admin');

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

-- Indexes
CREATE INDEX IF NOT EXISTS idx_issues_status_created_at ON issues (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_issues_reporter_id ON issues (reporter_id);
CREATE INDEX IF NOT EXISTS idx_issue_comments_issue_id ON issue_comments (issue_id);

-- updated_at trigger
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
