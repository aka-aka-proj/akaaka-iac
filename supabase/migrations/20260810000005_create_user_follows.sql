-- User following: one-way relationship, separate from bidirectional connections.
CREATE TABLE IF NOT EXISTS public.user_follows (
  follower_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  followed_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  PRIMARY KEY (follower_id, followed_id),
  CHECK (follower_id <> followed_id)
);

ALTER TABLE public.user_follows ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_follows_select_participant ON public.user_follows
  FOR SELECT TO authenticated
  USING (follower_id = (select auth.uid()) OR followed_id = (select auth.uid()));

CREATE POLICY user_follows_insert_self ON public.user_follows
  FOR INSERT TO authenticated
  WITH CHECK (
    follower_id = (select auth.uid())
    AND follower_id <> followed_id
  );

CREATE POLICY user_follows_delete_self ON public.user_follows
  FOR DELETE TO authenticated
  USING (follower_id = (select auth.uid()));

CREATE INDEX IF NOT EXISTS idx_user_follows_followed_id
  ON public.user_follows (followed_id);
CREATE INDEX IF NOT EXISTS idx_user_follows_follower_id
  ON public.user_follows (follower_id);
