-- Allow users to SELECT their own audit_logs entries
--
-- By default, audit_logs is admin-only (for both SELECT and INSERT).
-- This policy lets general users see entries where they are the target,
-- giving them visibility into admin actions that affect their account
-- (e.g., role upgrades, moderation actions).
--
-- Security: users can only see rows where target_profile_id = auth.uid(),
-- and cannot modify audit_logs in any way.

DROP POLICY IF EXISTS audit_logs_self_select ON audit_logs;
CREATE POLICY audit_logs_self_select ON audit_logs
  FOR SELECT TO authenticated
  USING (
    target_profile_id = auth.uid()
  );

-- Note: The existing audit_logs_admin_read policy remains in place
-- for admin users who can see ALL audit logs.
-- The system_insert policy also remains for service_role writes.