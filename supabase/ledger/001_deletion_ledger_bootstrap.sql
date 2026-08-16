-- Apply only to the independent deletion-ledger Supabase project.
-- Never copy this file into supabase/migrations/ for the application project.

CREATE TABLE IF NOT EXISTS public.deletion_ledger_events (
  subject TEXT NOT NULL,
  deletion_epoch BIGINT NOT NULL CHECK (deletion_epoch > 0),
  kind TEXT NOT NULL CHECK (kind IN ('account', 'lost_key', 'device_revoke', 'provider_key_revoke')),
  device_ids TEXT[] NOT NULL DEFAULT '{}'::TEXT[],
  provider_key_ids TEXT[] NOT NULL DEFAULT '{}'::TEXT[],
  idempotency_key TEXT PRIMARY KEY,
  created_at TIMESTAMPTZ NOT NULL,
  audit_actor TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'recorded'
    CHECK (status IN ('recorded', 'applied', 'verified', 'failed')),
  applied_at TIMESTAMPTZ,
  verified_at TIMESTAMPTZ,
  failure_code TEXT,
  CONSTRAINT deletion_ledger_failed_requires_code
    CHECK (status <> 'failed' OR failure_code IS NOT NULL),
  CONSTRAINT deletion_ledger_verified_requires_timestamp
    CHECK (status <> 'verified' OR verified_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS deletion_ledger_events_subject_created_idx
  ON public.deletion_ledger_events (subject, created_at, idempotency_key);

ALTER TABLE public.deletion_ledger_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.deletion_ledger_events FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.deletion_ledger_events TO service_role;

COMMENT ON TABLE public.deletion_ledger_events IS
  'Metadata-only independent deletion ledger; never stores content, ciphertext, key material, or provider secrets.';
COMMENT ON COLUMN public.deletion_ledger_events.subject IS
  'Opaque account subject; must not be directly identifying without a separately protected mapping.';
COMMENT ON COLUMN public.deletion_ledger_events.device_ids IS
  'Opaque device identifiers only; never private keys or wrapped key material.';
COMMENT ON COLUMN public.deletion_ledger_events.provider_key_ids IS
  'Opaque provider key identifiers only; never provider key plaintext.';
