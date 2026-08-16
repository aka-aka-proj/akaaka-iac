-- Issue #77: make the encrypted write path executable without enabling
-- plaintext writes. This is a forward-only compatibility migration.

-- Legacy values are retained only for the one-time browser migration. New
-- encrypted rows must be allowed to omit the legacy columns.
ALTER TABLE public.ai_messages
  ALTER COLUMN content DROP NOT NULL;

ALTER TABLE public.ai_characters
  ALTER COLUMN memory DROP NOT NULL;

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
