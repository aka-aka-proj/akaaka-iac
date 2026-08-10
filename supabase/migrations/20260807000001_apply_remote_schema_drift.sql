-- Extracted from the remote schema pull on 2026-08-07.
-- Keep only the actual schema drift that is not already owned by earlier migrations.

ALTER TABLE "public"."profiles"
  DROP CONSTRAINT IF EXISTS "profiles_social_links_min_one";

ALTER TABLE "public"."profiles"
  DROP CONSTRAINT IF EXISTS "profiles_role_status_check";

ALTER TABLE "public"."profiles"
  ADD CONSTRAINT "profiles_role_status_check"
  CHECK ((role_status = ANY (ARRAY['general'::text, 'venue_pending'::text, 'venue_approved'::text, 'admin'::text]))) NOT VALID;

ALTER TABLE "public"."profiles"
  VALIDATE CONSTRAINT "profiles_role_status_check";

ALTER TABLE "public"."ai_conversations"
  ADD COLUMN IF NOT EXISTS "updated_at" TIMESTAMPTZ NOT NULL DEFAULT NOW();

ALTER TABLE "public"."issue_comments"
  ALTER COLUMN "id" SET DEFAULT gen_random_uuid();

ALTER TABLE "public"."issues"
  ALTER COLUMN "id" SET DEFAULT gen_random_uuid();