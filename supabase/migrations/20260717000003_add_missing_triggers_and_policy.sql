-- Add missing triggers and policy not covered by initial schema

-- ─── Audit log: profile role_status change ─────────────────────────────────
-- Logs when role_status actually changes on a profile row.
-- SECURITY DEFINER so the trigger can bypass RLS on audit_logs.

CREATE OR REPLACE FUNCTION log_role_status_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF OLD.role_status IS DISTINCT FROM NEW.role_status THEN
    INSERT INTO audit_logs (actor_id, target_profile_id, action, payload)
    VALUES (
      COALESCE(auth.uid(), NEW.id),
      NEW.id,
      'role_status_change',
      jsonb_build_object('old', OLD.role_status, 'new', NEW.role_status)
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

-- ─── Audit log: moderation action inserted ─────────────────────────────────
-- Every new row in moderation_actions produces an audit_logs entry.
-- SECURITY DEFINER so the trigger can bypass RLS on audit_logs.

CREATE OR REPLACE FUNCTION log_moderation_action()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO audit_logs (actor_id, target_profile_id, action, payload)
  VALUES (
    NEW.admin_id,
    NEW.target_profile_id,
    NEW.action_type,
    NEW.payload
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_log_moderation_action ON moderation_actions;
CREATE TRIGGER trg_log_moderation_action
  AFTER INSERT ON moderation_actions
  FOR EACH ROW
  EXECUTE FUNCTION log_moderation_action();

-- ─── Recommendation rate limit (DB-level guard) ────────────────────────────
-- Enforces 1 recommendation per 24h per target at the database level,
-- catching any inserts that bypass the Edge Function.

CREATE OR REPLACE FUNCTION check_recommendation_rate_limit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  rec_count INT;
BEGIN
  SELECT COUNT(*) INTO rec_count
  FROM recommendations
  WHERE from_profile_id = NEW.from_profile_id
    AND to_profile_id = NEW.to_profile_id
    AND created_at > NOW() - INTERVAL '24 hours';

  IF rec_count >= 1 THEN
    RAISE EXCEPTION 'rate_limited: already recommended this person in the last 24 hours';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_recommendation_rate_limit ON recommendations;
CREATE TRIGGER trg_check_recommendation_rate_limit
  BEFORE INSERT ON recommendations
  FOR EACH ROW
  EXECUTE FUNCTION check_recommendation_rate_limit();

-- ─── Profiles INSERT policy ────────────────────────────────────────────────
-- Allows new users to insert their own profile row during onboarding.

DROP POLICY IF EXISTS profiles_insert_self ON profiles;
CREATE POLICY profiles_insert_self ON profiles
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = id);
