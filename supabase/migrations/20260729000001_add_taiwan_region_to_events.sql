-- Create taiwan_region enum type for event location filtering
-- 大分區模式：北中南東離島 + 線上，避免單一縣市活動過少造成空搜尋
create type public.taiwan_region as enum (
  'North',
  'Central',
  'South',
  'East',
  'Islands',
  'Online'
);

-- Add location columns to events table
alter table public.events
  add column if not exists location_region public.taiwan_region,
  add column if not exists location_detail text;

-- location_region is required for new events, but existing rows get null
-- (enforced at the application layer for now)