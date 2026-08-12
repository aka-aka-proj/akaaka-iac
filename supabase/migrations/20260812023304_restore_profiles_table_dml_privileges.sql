-- Column grants do not provide the table-level DML privilege required by the
-- Data API for profiles upsert/update. Restore the table gate, then keep the
-- protected fields unavailable to browser clients.
GRANT INSERT, UPDATE ON TABLE public.profiles TO authenticated;

REVOKE INSERT (
  role_status,
  reputation_score,
  created_at,
  updated_at
) ON TABLE public.profiles FROM authenticated;

REVOKE UPDATE (
  id,
  role_status,
  reputation_score,
  created_at,
  updated_at
) ON TABLE public.profiles FROM authenticated;
