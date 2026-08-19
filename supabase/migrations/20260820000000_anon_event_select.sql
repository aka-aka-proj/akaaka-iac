-- Allow anonymous users to view public event details by direct URL.
-- Also add denormalized creator display_name/avatar_path for anon-safe display.

-- Step 1: Add denormalized creator display columns
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS creator_display_name TEXT,
  ADD COLUMN IF NOT EXISTS creator_avatar_path TEXT;

-- Step 2: Backfill existing rows from profiles
UPDATE public.events e
SET
  creator_display_name = p.display_name,
  creator_avatar_path = p.metadata->>'avatar_path'
FROM public.profiles p
WHERE e.creator_id = p.id
  AND (e.creator_display_name IS NULL OR e.creator_avatar_path IS NULL);

-- Step 3: Create anon SELECT policy for public events
-- Anon can only see events that are published, non-draft, and publicly visible
DROP POLICY IF EXISTS events_anon_select_public ON public.events;
CREATE POLICY events_anon_select_public ON public.events
  FOR SELECT
  TO anon
  USING (
    lifecycle_status <> 'draft'
    AND publication_status = 'published'
    AND visibility_settings->>'type' = 'public'
  );

COMMENT ON POLICY events_anon_select_public ON public.events IS
  'Allow anonymous users to view public event details by direct URL';

-- Step 4: Grant table-level SELECT privilege to anon role
-- The Data API requires table privilege before RLS can filter rows.
GRANT SELECT ON public.events TO anon;