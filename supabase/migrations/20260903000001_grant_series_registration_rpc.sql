-- Keep privilege changes after the atomic function migration.
-- Supabase CLI statement splitting misparses trailing statements after a
-- function whose identifier contains `atomic`.
REVOKE ALL ON FUNCTION public.register_event_series_atomic(UUID, UUID, JSONB) FROM PUBLIC, anon, authenticated;
