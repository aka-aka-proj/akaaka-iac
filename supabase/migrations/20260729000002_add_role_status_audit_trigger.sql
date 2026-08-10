-- Audit Trigger for role_status changes on profiles
--
-- Logs any role_status change to the audit_logs table.
-- When auth.uid() is available (authenticated session), it's recorded as actor_id.
-- When auth.uid() is null (service_role operations like admin-role-upgrade edge function),
-- the edge function handles audit logging separately, so trigger skips to avoid duplication.
--
-- This covers: user self-updates (REST API) and any direct DB changes.

CREATE OR REPLACE FUNCTION log_role_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Only log when role_status actually changes AND we have an authenticated user
  -- (service_role operations log via edge function, not here)
  IF OLD.role_status IS DISTINCT FROM NEW.role_status AND auth.uid() IS NOT NULL THEN
    INSERT INTO audit_logs (actor_id, target_profile_id, action, payload)
    VALUES (
      auth.uid(),
      NEW.id,
      'role_status_change',
      jsonb_build_object(
        'old_status', OLD.role_status,
        'new_status', NEW.role_status
      )
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_log_role_status_change ON profiles;
CREATE TRIGGER trg_log_role_status_change
AFTER UPDATE ON profiles
FOR EACH ROW
EXECUTE FUNCTION log_role_status_change();