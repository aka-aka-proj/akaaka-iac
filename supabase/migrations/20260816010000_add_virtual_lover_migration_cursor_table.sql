-- Issue #77: make the two-table browser migration resumable without ambiguity.
-- The cursor belongs to one deterministic table at a time; no content is read.

ALTER TABLE public.ai_encryption_migrations
  ADD COLUMN IF NOT EXISTS cursor_table TEXT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.ai_encryption_migrations'::regclass
      AND conname = 'ai_encryption_migrations_cursor_table_valid'
  ) THEN
    ALTER TABLE public.ai_encryption_migrations
      ADD CONSTRAINT ai_encryption_migrations_cursor_table_valid
      CHECK (cursor_table IS NULL OR cursor_table IN ('ai_characters', 'ai_messages'));
  END IF;
END;
$$;

COMMENT ON COLUMN public.ai_encryption_migrations.cursor_table IS
  'Current deterministic legacy migration table; NULL after completion.';
