-- Grant table-level SELECT privilege to anon role for public events access.
-- The Data API requires table privilege before RLS can filter rows.
-- This must be a separate migration because 20260820000000 was already
-- applied without this GRANT, and db push cannot re-apply an existing file.

GRANT SELECT ON public.events TO anon;