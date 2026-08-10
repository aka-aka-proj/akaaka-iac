-- Personal event bookmarks. Visibility of the joined event remains governed by events RLS.
CREATE TABLE IF NOT EXISTS public.event_bookmarks (
  profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
  PRIMARY KEY (profile_id, event_id)
);

ALTER TABLE public.event_bookmarks ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_event_bookmarks_event_id
  ON public.event_bookmarks (event_id);

DROP POLICY IF EXISTS event_bookmarks_select_self ON public.event_bookmarks;
CREATE POLICY event_bookmarks_select_self
  ON public.event_bookmarks
  FOR SELECT
  TO authenticated
  USING ((SELECT auth.uid()) = profile_id);

DROP POLICY IF EXISTS event_bookmarks_insert_self ON public.event_bookmarks;
CREATE POLICY event_bookmarks_insert_self
  ON public.event_bookmarks
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (SELECT auth.uid()) = profile_id
    AND EXISTS (
      SELECT 1
      FROM public.events
      WHERE public.events.id = event_bookmarks.event_id
    )
  );

DROP POLICY IF EXISTS event_bookmarks_delete_self ON public.event_bookmarks;
CREATE POLICY event_bookmarks_delete_self
  ON public.event_bookmarks
  FOR DELETE
  TO authenticated
  USING ((SELECT auth.uid()) = profile_id);
