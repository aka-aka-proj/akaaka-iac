-- Keep moderation writes bound to the trusted admin claim.
CREATE OR REPLACE FUNCTION public.set_profile_moderation_status(
  target_id uuid,
  moderation_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF (
    SELECT auth.jwt() -> 'app_metadata' ->> 'role'
  ) NOT IN ('admin', 'service_role') THEN
    RAISE EXCEPTION 'controlled backend required'
      USING errcode = '42501';
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
$$;
