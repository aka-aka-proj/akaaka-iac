-- Issue #77: client-side encrypted Virtual Lover sync foundation.
-- This migration adds only ciphertext/key metadata and resumable migration state.
-- It does not read, transform, or delete legacy plaintext.

ALTER TABLE public.ai_characters
  ADD COLUMN IF NOT EXISTS memory_ciphertext TEXT,
  ADD COLUMN IF NOT EXISTS memory_nonce TEXT,
  ADD COLUMN IF NOT EXISTS memory_key_version INTEGER,
  ADD COLUMN IF NOT EXISTS memory_aad_version INTEGER;

ALTER TABLE public.ai_messages
  ADD COLUMN IF NOT EXISTS content_ciphertext TEXT,
  ADD COLUMN IF NOT EXISTS content_nonce TEXT,
  ADD COLUMN IF NOT EXISTS content_key_version INTEGER,
  ADD COLUMN IF NOT EXISTS content_aad_version INTEGER;

CREATE TABLE IF NOT EXISTS public.ai_encryption_devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_label TEXT NOT NULL CHECK (char_length(btrim(device_label)) BETWEEN 1 AND 120),
  public_key_jwk TEXT NOT NULL,
  key_version INTEGER NOT NULL DEFAULT 1 CHECK (key_version > 0),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  UNIQUE (user_id, id)
);

CREATE TABLE IF NOT EXISTS public.ai_encryption_vault_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id UUID NOT NULL REFERENCES public.ai_encryption_devices(id) ON DELETE CASCADE,
  wrapped_data_key TEXT NOT NULL,
  wrap_algorithm TEXT NOT NULL DEFAULT 'RSA-OAEP-3072-SHA256',
  key_version INTEGER NOT NULL DEFAULT 1 CHECK (key_version > 0),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at TIMESTAMPTZ,
  UNIQUE (device_id, key_version),
  UNIQUE (user_id, device_id, key_version)
);

CREATE TABLE IF NOT EXISTS public.ai_encryption_migrations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  target_version INTEGER NOT NULL CHECK (target_version > 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'in_progress', 'complete', 'blocked', 'cancelled')),
  cursor_created_at TIMESTAMPTZ,
  cursor_id UUID,
  legacy_rows_seen INTEGER NOT NULL DEFAULT 0 CHECK (legacy_rows_seen >= 0),
  encrypted_rows_verified INTEGER NOT NULL DEFAULT 0 CHECK (encrypted_rows_verified >= 0),
  legacy_rows_cleared INTEGER NOT NULL DEFAULT 0 CHECK (legacy_rows_cleared >= 0),
  failure_code TEXT CHECK (failure_code IS NULL OR failure_code ~ '^[a-z0-9_]+$'),
  started_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_ai_encryption_devices_user_status
  ON public.ai_encryption_devices (user_id, status);
CREATE INDEX IF NOT EXISTS idx_ai_encryption_vault_keys_user_device
  ON public.ai_encryption_vault_keys (user_id, device_id, status);

ALTER TABLE public.ai_encryption_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_encryption_vault_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_encryption_migrations ENABLE ROW LEVEL SECURITY;

CREATE POLICY ai_encryption_devices_select_owner
  ON public.ai_encryption_devices FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) = user_id);
CREATE POLICY ai_encryption_devices_insert_owner
  ON public.ai_encryption_devices FOR INSERT TO authenticated
  WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY ai_encryption_devices_update_owner
  ON public.ai_encryption_devices FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = user_id)
  WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY ai_encryption_devices_delete_owner
  ON public.ai_encryption_devices FOR DELETE TO authenticated
  USING ((SELECT auth.uid()) = user_id);

CREATE POLICY ai_encryption_vault_keys_select_owner
  ON public.ai_encryption_vault_keys FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) = user_id);
CREATE POLICY ai_encryption_vault_keys_insert_owner
  ON public.ai_encryption_vault_keys FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT auth.uid()) = user_id
    AND EXISTS (
      SELECT 1 FROM public.ai_encryption_devices d
      WHERE d.id = device_id AND d.user_id = (SELECT auth.uid()) AND d.status = 'active'
    )
  );
CREATE POLICY ai_encryption_vault_keys_update_owner
  ON public.ai_encryption_vault_keys FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = user_id)
  WITH CHECK (
    (SELECT auth.uid()) = user_id
    AND EXISTS (
      SELECT 1 FROM public.ai_encryption_devices d
      WHERE d.id = device_id AND d.user_id = (SELECT auth.uid())
    )
  );
CREATE POLICY ai_encryption_vault_keys_delete_owner
  ON public.ai_encryption_vault_keys FOR DELETE TO authenticated
  USING ((SELECT auth.uid()) = user_id);

CREATE POLICY ai_encryption_migrations_select_owner
  ON public.ai_encryption_migrations FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) = user_id);
CREATE POLICY ai_encryption_migrations_insert_owner
  ON public.ai_encryption_migrations FOR INSERT TO authenticated
  WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY ai_encryption_migrations_update_owner
  ON public.ai_encryption_migrations FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = user_id)
  WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY ai_encryption_migrations_delete_owner
  ON public.ai_encryption_migrations FOR DELETE TO authenticated
  USING ((SELECT auth.uid()) = user_id);

-- No browser path may insert or update new plaintext message content.
REVOKE INSERT, UPDATE ON public.ai_messages FROM authenticated;
GRANT INSERT (conversation_id, role, content_ciphertext, content_nonce, content_key_version, content_aad_version, created_at)
  ON public.ai_messages TO authenticated;
GRANT UPDATE (content_ciphertext, content_nonce, content_key_version, content_aad_version)
  ON public.ai_messages TO authenticated;

-- Character configuration remains editable; memory writes use encrypted columns only.
REVOKE INSERT, UPDATE ON public.ai_characters FROM authenticated;
GRANT INSERT (user_id, name, persona, memory_ciphertext, memory_nonce, memory_key_version, memory_aad_version, created_at)
  ON public.ai_characters TO authenticated;
GRANT UPDATE (name, persona, memory_ciphertext, memory_nonce, memory_key_version, memory_aad_version)
  ON public.ai_characters TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_encryption_devices TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_encryption_vault_keys TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_encryption_migrations TO authenticated;

COMMENT ON TABLE public.ai_encryption_devices IS 'Non-content device public-key metadata only; never private keys.';
COMMENT ON TABLE public.ai_encryption_vault_keys IS 'Wrapped vault data keys only; never raw data keys.';
COMMENT ON TABLE public.ai_encryption_migrations IS 'Resumable migration state only; never plaintext or content hashes.';
