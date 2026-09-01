-- Keep both atomic registration RPCs service-role-only.
DO $$
BEGIN
  REVOKE ALL ON FUNCTION public.register_event_series_atomic(UUID, UUID, JSONB, UUID[]) FROM PUBLIC, anon, authenticated;
  GRANT EXECUTE ON FUNCTION public.register_event_series_atomic(UUID, UUID, JSONB, UUID[]) TO service_role;
  REVOKE ALL ON FUNCTION public.create_event_registration_atomic(UUID, UUID) FROM PUBLIC, anon, authenticated;
  GRANT EXECUTE ON FUNCTION public.create_event_registration_atomic(UUID, UUID) TO service_role;
END;
$$;
