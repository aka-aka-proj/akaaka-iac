-- Direct messaging authorization follows mutual user_follows, not connections.

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
    SELECT 1 FROM public.user_follows
    WHERE follower_id = current_user_id AND followed_id = p_other_profile_id
  ) OR NOT EXISTS (
    SELECT 1 FROM public.user_follows
    WHERE follower_id = p_other_profile_id AND followed_id = current_user_id
  ) THEN
    RAISE EXCEPTION 'mutual follow required';
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

DROP POLICY IF EXISTS direct_conversations_select_participant ON public.direct_conversations;
DROP POLICY IF EXISTS direct_messages_select_participant ON public.direct_messages;
DROP POLICY IF EXISTS direct_messages_insert_participant ON public.direct_messages;
DROP POLICY IF EXISTS direct_messages_realtime_select ON realtime.messages;

CREATE POLICY direct_conversations_select_participant
  ON public.direct_conversations FOR SELECT TO authenticated
  USING (
    (participant_one_id = (SELECT auth.uid()) OR participant_two_id = (SELECT auth.uid()))
    AND EXISTS (
      SELECT 1 FROM public.user_follows f1
      WHERE f1.follower_id = participant_one_id AND f1.followed_id = participant_two_id
    )
    AND EXISTS (
      SELECT 1 FROM public.user_follows f2
      WHERE f2.follower_id = participant_two_id AND f2.followed_id = participant_one_id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.blocks b
      WHERE (b.blocker_id = participant_one_id AND b.blocked_id = participant_two_id)
         OR (b.blocker_id = participant_two_id AND b.blocked_id = participant_one_id)
    )
  );

CREATE POLICY direct_messages_select_participant
  ON public.direct_messages FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.direct_conversations c
    WHERE c.id = direct_messages.conversation_id
      AND (c.participant_one_id = (SELECT auth.uid()) OR c.participant_two_id = (SELECT auth.uid()))
      AND EXISTS (SELECT 1 FROM public.user_follows f1 WHERE f1.follower_id = c.participant_one_id AND f1.followed_id = c.participant_two_id)
      AND EXISTS (SELECT 1 FROM public.user_follows f2 WHERE f2.follower_id = c.participant_two_id AND f2.followed_id = c.participant_one_id)
      AND NOT EXISTS (
        SELECT 1 FROM public.blocks b
        WHERE (b.blocker_id = c.participant_one_id AND b.blocked_id = c.participant_two_id)
           OR (b.blocker_id = c.participant_two_id AND b.blocked_id = c.participant_one_id)
      )
  ));

CREATE POLICY direct_messages_insert_participant
  ON public.direct_messages FOR INSERT TO authenticated
  WITH CHECK (
    sender_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.direct_conversations c
      WHERE c.id = direct_messages.conversation_id
        AND (c.participant_one_id = (SELECT auth.uid()) OR c.participant_two_id = (SELECT auth.uid()))
        AND EXISTS (SELECT 1 FROM public.user_follows f1 WHERE f1.follower_id = c.participant_one_id AND f1.followed_id = c.participant_two_id)
        AND EXISTS (SELECT 1 FROM public.user_follows f2 WHERE f2.follower_id = c.participant_two_id AND f2.followed_id = c.participant_one_id)
        AND NOT EXISTS (
          SELECT 1 FROM public.blocks b
          WHERE (b.blocker_id = c.participant_one_id AND b.blocked_id = c.participant_two_id)
             OR (b.blocker_id = c.participant_two_id AND b.blocked_id = c.participant_one_id)
        )
    )
  );

CREATE POLICY direct_messages_realtime_select
  ON realtime.messages FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.direct_conversations c
      WHERE realtime.messages.topic = 'direct-conversation:' || c.id::text
        AND (c.participant_one_id = (SELECT auth.uid()) OR c.participant_two_id = (SELECT auth.uid()))
        AND EXISTS (SELECT 1 FROM public.user_follows f1 WHERE f1.follower_id = c.participant_one_id AND f1.followed_id = c.participant_two_id)
        AND EXISTS (SELECT 1 FROM public.user_follows f2 WHERE f2.follower_id = c.participant_two_id AND f2.followed_id = c.participant_one_id)
        AND NOT EXISTS (
          SELECT 1 FROM public.blocks b
          WHERE (b.blocker_id = c.participant_one_id AND b.blocked_id = c.participant_two_id)
             OR (b.blocker_id = c.participant_two_id AND b.blocked_id = c.participant_one_id)
        )
    )
  );
