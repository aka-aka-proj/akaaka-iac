-- Remove the old unique constraint
ALTER TABLE "public"."event_registrations"
DROP CONSTRAINT IF EXISTS "event_registrations_event_id_profile_id_key";

-- Create a partial unique index that only enforces uniqueness for non-cancelled registrations
CREATE UNIQUE INDEX IF NOT EXISTS "unique_active_registration"
ON "public"."event_registrations" ("event_id", "profile_id")
WHERE "status" != 'cancelled';
