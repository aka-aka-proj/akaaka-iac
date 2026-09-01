-- Remove the superseded three-argument overload after the four-argument RPC exists.
DROP FUNCTION IF EXISTS public.register_event_series_atomic(UUID, UUID, JSONB);
