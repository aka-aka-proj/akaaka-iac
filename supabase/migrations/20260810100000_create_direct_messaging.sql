-- Direct messaging: one-to-one conversations for mutually accepted connections.

CREATE TABLE IF NOT EXISTS public.direct_conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_one_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  participant_two_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT direct_conversations_participant_order
    CHECK (participant_one_id < participant_two_id),
  CONSTRAINT direct_conversations_unique_pair
    UNIQUE (participant_one_id, participant_two_id)
);

CREATE TABLE IF NOT EXISTS public.direct_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES public.direct_conversations(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  content TEXT NOT NULL CHECK (char_length(btrim(content)) BETWEEN 1 AND 4000),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_direct_messages_conversation_created_at
  ON public.direct_messages (conversation_id, created_at);

CREATE INDEX IF NOT EXISTS idx_direct_conversations_participants
  ON public.direct_conversations (participant_one_id, participant_two_id);

ALTER TABLE public.direct_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_messages ENABLE ROW LEVEL SECURITY;

-- The RPC sets this transaction-local marker, so direct table inserts cannot
-- create conversations while still keeping the RPC SECURITY INVOKER.
CREATE OR REPLACE FUNCTION public.create_direct_conversation(p_other_profile_id UUID)
RETURNS TABLE (id UUID)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_user_id UUID := auth.uid();
  first_id UUID;
  second_id UUID;
  conversation_id UUID;
BEGIN
  IF current_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  IF p_other_profile_id IS NULL OR p_other_profile_id = current_user_id THEN
    RAISE EXCEPTION 'invalid conversation participant';
  END IF;

  first_id := LEAST(current_user_id, p_other_profile_id);
  second_id := GREATEST(current_user_id, p_other_profile_id);

  IF EXISTS (
    SELECT 1 FROM public.blocks
    WHERE (blocker_id = current_user_id AND blocked_id = p_other_profile_id)
       OR (blocker_id = p_other_profile_id AND blocked_id = current_user_id)
  ) THEN
    RAISE EXCEPTION 'conversation unavailable';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.connections
    WHERE requester_id = current_user_id
      AND receiver_id = p_other_profile_id
      AND status = 'accepted'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.connections
    WHERE requester_id = p_other_profile_id
      AND receiver_id = current_user_id
      AND status = 'accepted'
  ) THEN
    RAISE EXCEPTION 'accepted connection required';
  END IF;

  PERFORM set_config('app.direct_conversation_rpc', 'on', true);
  INSERT INTO public.direct_conversations (participant_one_id, participant_two_id)
  VALUES (first_id, second_id)
  ON CONFLICT (participant_one_id, participant_two_id) DO NOTHING;

  SELECT c.id INTO conversation_id
  FROM public.direct_conversations AS c
  WHERE c.participant_one_id = first_id
    AND c.participant_two_id = second_id;

  RETURN QUERY SELECT conversation_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_direct_conversation(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_direct_conversation(UUID) TO authenticated;

CREATE POLICY direct_conversations_select_participant
  ON public.direct_conversations FOR SELECT TO authenticated
  USING (
    (participant_one_id = (SELECT auth.uid()) OR participant_two_id = (SELECT auth.uid()))
    AND EXISTS (
      SELECT 1 FROM public.connections c1
      WHERE c1.requester_id = participant_one_id
        AND c1.receiver_id = participant_two_id
        AND c1.status = 'accepted'
    )
    AND EXISTS (
      SELECT 1 FROM public.connections c2
      WHERE c2.requester_id = participant_two_id
        AND c2.receiver_id = participant_one_id
        AND c2.status = 'accepted'
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.blocks b
      WHERE (b.blocker_id = participant_one_id AND b.blocked_id = participant_two_id)
         OR (b.blocker_id = participant_two_id AND b.blocked_id = participant_one_id)
    )
  );

CREATE POLICY direct_conversations_insert_rpc_only
  ON public.direct_conversations FOR INSERT TO authenticated
  WITH CHECK (
    current_setting('app.direct_conversation_rpc', true) = 'on'
    AND (participant_one_id = (SELECT auth.uid()) OR participant_two_id = (SELECT auth.uid()))
  );

CREATE POLICY direct_messages_select_participant
  ON public.direct_messages FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.direct_conversations c
    WHERE c.id = direct_messages.conversation_id
  ));

CREATE POLICY direct_messages_insert_participant
  ON public.direct_messages FOR INSERT TO authenticated
  WITH CHECK (
    sender_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.direct_conversations c
      WHERE c.id = direct_messages.conversation_id
    )
  );

-- Realtime authorization is evaluated when the private channel is joined.
CREATE POLICY direct_messages_realtime_select
  ON realtime.messages FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.direct_conversations c
      WHERE realtime.messages.topic = 'direct-conversation:' || c.id::text
        AND (c.participant_one_id = (SELECT auth.uid()) OR c.participant_two_id = (SELECT auth.uid()))
        AND EXISTS (
          SELECT 1 FROM public.connections c1
          WHERE c1.requester_id = c.participant_one_id
            AND c1.receiver_id = c.participant_two_id
            AND c1.status = 'accepted'
        )
        AND EXISTS (
          SELECT 1 FROM public.connections c2
          WHERE c2.requester_id = c.participant_two_id
            AND c2.receiver_id = c.participant_one_id
            AND c2.status = 'accepted'
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.blocks b
          WHERE (b.blocker_id = c.participant_one_id AND b.blocked_id = c.participant_two_id)
             OR (b.blocker_id = c.participant_two_id AND b.blocked_id = c.participant_one_id)
        )
    )
  );

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.direct_messages;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END;
$$;
