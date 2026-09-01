-- Grant the RPC only to the service role used by the trusted Edge Function.
GRANT EXECUTE ON FUNCTION public.register_event_series_atomic(UUID, UUID, JSONB) TO service_role;
