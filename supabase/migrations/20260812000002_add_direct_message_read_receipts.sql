-- Add per-message read receipts. Only the recipient may set read_at.
ALTER TABLE public.direct_messages
  ADD COLUMN IF NOT EXISTS read_at TIMESTAMPTZ;

GRANT SELECT, INSERT ON public.direct_messages TO authenticated;
GRANT UPDATE (read_at) ON public.direct_messages TO authenticated;

DROP POLICY IF EXISTS direct_messages_update_read_at ON public.direct_messages;
CREATE POLICY direct_messages_update_read_at
  ON public.direct_messages FOR UPDATE TO authenticated
  USING (
    sender_id <> (SELECT auth.uid())
    AND EXISTS (
      SELECT 1
      FROM public.direct_conversations c
      WHERE c.id = direct_messages.conversation_id
        AND (c.participant_one_id = (SELECT auth.uid()) OR c.participant_two_id = (SELECT auth.uid()))
        AND EXISTS (
          SELECT 1 FROM public.user_follows f1
          WHERE f1.follower_id = c.participant_one_id AND f1.followed_id = c.participant_two_id
        )
        AND EXISTS (
          SELECT 1 FROM public.user_follows f2
          WHERE f2.follower_id = c.participant_two_id AND f2.followed_id = c.participant_one_id
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.blocks b
          WHERE (b.blocker_id = c.participant_one_id AND b.blocked_id = c.participant_two_id)
             OR (b.blocker_id = c.participant_two_id AND b.blocked_id = c.participant_one_id)
        )
    )
  )
  WITH CHECK (
    sender_id <> (SELECT auth.uid())
    AND read_at IS NOT NULL
  );
