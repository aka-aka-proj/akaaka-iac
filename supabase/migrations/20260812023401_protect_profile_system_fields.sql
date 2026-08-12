-- The Data API requires table-level DML privileges for profiles upsert/update.
-- Keep system-owned fields protected with a trigger after restoring that gate.
CREATE OR REPLACE FUNCTION public.protect_profile_system_fields()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF current_user = 'authenticated' THEN
    IF TG_OP = 'INSERT' THEN
      NEW.role_status := 'general';
      NEW.reputation_score := 0;
      NEW.created_at := TIMEZONE('utc', NOW());
      NEW.updated_at := TIMEZONE('utc', NOW());
    ELSE
      NEW.id := OLD.id;
      NEW.role_status := OLD.role_status;
      NEW.reputation_score := OLD.reputation_score;
      NEW.created_at := OLD.created_at;
      NEW.updated_at := TIMEZONE('utc', NOW());
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_profile_system_fields ON public.profiles;
CREATE TRIGGER trg_protect_profile_system_fields
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_profile_system_fields();
