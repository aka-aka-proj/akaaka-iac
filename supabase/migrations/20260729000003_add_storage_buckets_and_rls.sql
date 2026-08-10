-- Supabase Storage buckets for user-uploaded content
--
-- Creates two buckets:
--   - avatars: user profile pictures
--   - event-covers: event cover images
--
-- RLS policies:
--   - Public read (SELECT) for authenticated users
--   - Owner-only write (INSERT/UPDATE/DELETE) for file owners
--
-- See: docs/spec/007-asset-storage-spec.md

-- ============================================================
-- Helper: insert policy for a bucket (owner-only write)
-- ============================================================
-- Note: Storage RLS policies use the `storage` schema and the
-- `bucket_id` column on `storage.objects` table.

-- ============================================================
-- 1) avatars bucket
-- ============================================================
INSERT INTO storage.buckets (id, name, public, avif_autodetection, file_size_limit, allowed_mime_types)
VALUES ('avatars', 'avatars', true, false, 5242880, ARRAY['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
ON CONFLICT (id) DO NOTHING;

-- Allow authenticated users to read any avatar
DROP POLICY IF EXISTS avatars_select_auth ON storage.objects;
CREATE POLICY avatars_select_auth ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'avatars');

-- Allow authenticated users to insert their own avatar
DROP POLICY IF EXISTS avatars_insert_owner ON storage.objects;
CREATE POLICY avatars_insert_owner ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Allow owner to update their avatar
DROP POLICY IF EXISTS avatars_update_owner ON storage.objects;
CREATE POLICY avatars_update_owner ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Allow owner to delete their avatar
DROP POLICY IF EXISTS avatars_delete_owner ON storage.objects;
CREATE POLICY avatars_delete_owner ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- ============================================================
-- 2) event-covers bucket
-- ============================================================
INSERT INTO storage.buckets (id, name, public, avif_autodetection, file_size_limit, allowed_mime_types)
VALUES ('event-covers', 'event-covers', true, false, 10485760, ARRAY['image/png', 'image/jpeg', 'image/webp'])
ON CONFLICT (id) DO NOTHING;

-- Allow authenticated users to read any event cover
DROP POLICY IF EXISTS event_covers_select_auth ON storage.objects;
CREATE POLICY event_covers_select_auth ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'event-covers');

-- Allow authenticated users to insert their own event cover
DROP POLICY IF EXISTS event_covers_insert_owner ON storage.objects;
CREATE POLICY event_covers_insert_owner ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'event-covers'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Allow owner to update their event cover
DROP POLICY IF EXISTS event_covers_update_owner ON storage.objects;
CREATE POLICY event_covers_update_owner ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'event-covers'
    AND (storage.foldername(name))[1] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'event-covers'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Allow owner to delete their event cover
DROP POLICY IF EXISTS event_covers_delete_owner ON storage.objects;
CREATE POLICY event_covers_delete_owner ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'event-covers'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );