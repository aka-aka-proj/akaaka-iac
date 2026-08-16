-- Issue #77: make the encrypted write path executable without enabling
-- plaintext writes. This is a forward-only compatibility migration.

-- Legacy values are retained only for the one-time browser migration. New
-- encrypted rows must be allowed to omit the legacy columns.
ALTER TABLE public.ai_messages
  ALTER COLUMN content DROP NOT NULL;

ALTER TABLE public.ai_characters
  ALTER COLUMN memory DROP NOT NULL;

-- Allow the browser migration to clear legacy values while preventing any
-- client path from inserting or changing plaintext after this migration.
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;

CREATE OR REPLACE FUNCTION private.prevent_ai_plaintext_writes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF TG_TABLE_NAME = 'ai_messages' THEN
    IF TG_OP = 'INSERT' AND NEW.content IS NOT NULL THEN
      RAISE EXCEPTION 'legacy_plaintext_write_denied';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.content IS NOT NULL AND NEW.content IS DISTINCT FROM OLD.content THEN
      RAISE EXCEPTION 'legacy_plaintext_write_denied';
    END IF;
  ELSIF TG_TABLE_NAME = 'ai_characters' THEN
    IF TG_OP = 'INSERT' AND NEW.memory IS NOT NULL THEN
      RAISE EXCEPTION 'legacy_plaintext_write_denied';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.memory IS NOT NULL AND NEW.memory IS DISTINCT FROM OLD.memory THEN
      RAISE EXCEPTION 'legacy_plaintext_write_denied';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.prevent_ai_plaintext_writes() FROM PUBLIC;

DROP TRIGGER IF EXISTS ai_messages_prevent_plaintext_writes ON public.ai_messages;
CREATE TRIGGER ai_messages_prevent_plaintext_writes
  BEFORE INSERT OR UPDATE ON public.ai_messages
  FOR EACH ROW EXECUTE FUNCTION private.prevent_ai_plaintext_writes();

DROP TRIGGER IF EXISTS ai_characters_prevent_plaintext_writes ON public.ai_characters;
CREATE TRIGGER ai_characters_prevent_plaintext_writes
  BEFORE INSERT OR UPDATE ON public.ai_characters
  FOR EACH ROW EXECUTE FUNCTION private.prevent_ai_plaintext_writes();

-- Column grants permit the migration's NULL clear only; the trigger rejects
-- non-null plaintext writes.
GRANT UPDATE (content) ON public.ai_messages TO authenticated;
GRANT UPDATE (memory) ON public.ai_characters TO authenticated;

-- RLS UPDATE needs both a SELECT policy and an owner-scoped UPDATE policy.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'ai_messages'
      AND policyname = 'ai_messages_update_owner'
  ) THEN
    CREATE POLICY ai_messages_update_owner
      ON public.ai_messages FOR UPDATE TO authenticated
      USING (
        EXISTS (
          SELECT 1 FROM public.ai_conversations acv
          JOIN public.ai_characters ac ON ac.id = acv.character_id
          WHERE acv.id = conversation_id AND ac.user_id = (SELECT auth.uid())
        )
      )
      WITH CHECK (
        EXISTS (
          SELECT 1 FROM public.ai_conversations acv
          JOIN public.ai_characters ac ON ac.id = acv.character_id
          WHERE acv.id = conversation_id AND ac.user_id = (SELECT auth.uid())
        )
      );
  END IF;
END
$$;

-- The old chat function must not be able to write new plaintext memory.
REVOKE UPDATE (memory) ON public.ai_characters FROM authenticated;

-- Public-key material is metadata only. Reject obvious private JWK members at
-- the database boundary; the browser still remains responsible for producing
-- a valid public JWK and the contract test covers this invariant.
ALTER TABLE public.ai_encryption_devices
  ADD CONSTRAINT ai_encryption_devices_public_key_is_public
  CHECK (
    public_key_jwk NOT LIKE '%"d"%'
    AND public_key_jwk NOT LIKE '%"p"%'
    AND public_key_jwk NOT LIKE '%"q"%'
    AND public_key_jwk NOT LIKE '%"dp"%'
    AND public_key_jwk NOT LIKE '%"dq"%'
    AND public_key_jwk NOT LIKE '%"qi"%'
  ) NOT VALID;
