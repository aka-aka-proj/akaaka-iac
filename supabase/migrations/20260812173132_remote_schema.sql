drop extension if exists "pg_net";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.apply_recommendation_score()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  weight NUMERIC := 1.0;
BEGIN
  IF EXISTS (
    SELECT 1 FROM profiles p
    WHERE p.id = NEW.from_profile_id AND p.role_status = 'venue_approved'
  ) THEN
    weight := 1.5;
  END IF;

  UPDATE profiles
    SET reputation_score = reputation_score + CEIL(NEW.score_increment * weight)::INT
  WHERE id = NEW.to_profile_id;

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.protect_profile_system_fields()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.set_profile_moderation_status(target_id uuid, moderation_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF (select auth.jwt() ->> 'role') NOT IN ('admin', 'service_role') THEN
    RAISE EXCEPTION 'controlled backend required' USING errcode = '42501';
  END IF;

  UPDATE public.profiles
  SET metadata = jsonb_set(
    COALESCE(metadata, '{}'::jsonb),
    '{moderation_status}',
    to_jsonb(moderation_status),
    true
  )
  WHERE id = target_id;
END;
$function$
;


