ALTER TABLE "public"."event_registrations"
DROP CONSTRAINT "event_registrations_status_check";

ALTER TABLE "public"."event_registrations"
ADD CONSTRAINT "event_registrations_status_check"
CHECK (("status" = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text, 'cancelled'::text, 'waitlisted'::text, 'cancellation_pending'::text, 'cancellation_rejected'::text])));
