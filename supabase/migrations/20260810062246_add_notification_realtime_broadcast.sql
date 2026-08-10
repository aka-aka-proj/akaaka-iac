-- Notify online recipients without exposing notification contents.
-- Historical notification state remains in public.notifications and is read through RLS.

CREATE SCHEMA IF NOT EXISTS private;

CREATE OR REPLACE FUNCTION private.broadcast_new_notification()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM realtime.send(
    jsonb_build_object('notification_id', NEW.id, 'refresh', true),
    'new_notification',
    'user:' || NEW.recipient_profile_id::text,
    true
  );
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.broadcast_new_notification() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_broadcast_new_notification ON public.notifications;
CREATE TRIGGER trg_broadcast_new_notification
AFTER INSERT ON public.notifications
FOR EACH ROW
EXECUTE FUNCTION private.broadcast_new_notification();

ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notifications_realtime_receive_self ON realtime.messages;
CREATE POLICY notifications_realtime_receive_self
ON realtime.messages
FOR SELECT
TO authenticated
USING (topic = 'user:' || (select auth.uid())::text);
