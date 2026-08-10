-- Draft events are private to their creator regardless of visibility_settings.
DROP POLICY IF EXISTS events_read_visibility ON events;

CREATE POLICY events_read_visibility ON events FOR SELECT TO authenticated
USING (
  creator_id = auth.uid()
  OR (
    lifecycle_status <> 'draft'
    AND (
      (visibility_settings ->> 'type') IS NULL
      OR (visibility_settings ->> 'type') = 'public'
      OR (
        (visibility_settings ->> 'type') = 'connections_only'
        AND EXISTS (
          SELECT 1 FROM connections c
          WHERE c.status = 'accepted'
            AND (
              (c.requester_id = auth.uid() AND c.receiver_id = events.creator_id)
              OR
              (c.requester_id = events.creator_id AND c.receiver_id = auth.uid())
            )
        )
      )
    )
  )
);
