CREATE TABLE IF NOT EXISTS public.user_llm_api_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL DEFAULT 'openrouter' CHECK (provider = 'openrouter'),
  provider_key_hash TEXT NOT NULL UNIQUE,
  encrypted_key TEXT NOT NULL,
  key_version INTEGER NOT NULL DEFAULT 1 CHECK (key_version > 0),
  limit_usd NUMERIC(12, 6),
  limit_reset TEXT CHECK (limit_reset IN ('daily', 'weekly', 'monthly')),
  disabled BOOLEAN NOT NULL DEFAULT false,
  usage_usd NUMERIC(12, 6),
  limit_remaining_usd NUMERIC(12, 6),
  provider_created_at TIMESTAMPTZ,
  provider_updated_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.user_llm_api_keys ENABLE ROW LEVEL SECURITY;

-- The table is intentionally server-only. No Data API role receives access,
-- because even encrypted provider credentials are not client-readable.
REVOKE ALL ON public.user_llm_api_keys FROM anon, authenticated;

CREATE INDEX IF NOT EXISTS idx_user_llm_api_keys_user_id
  ON public.user_llm_api_keys (user_id);
