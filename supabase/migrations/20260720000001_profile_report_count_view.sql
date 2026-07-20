-- Profile report count view
-- Aggregates report counts per profile for public display.
-- Owned by postgres to bypass the underlying `reports` table RLS.
-- Only the aggregated count is exposed — no individual report details.

CREATE OR REPLACE VIEW profile_report_stats AS
SELECT
  target_profile_id AS profile_id,
  COUNT(*) AS report_count
FROM reports
WHERE target_profile_id IS NOT NULL
GROUP BY target_profile_id;

ALTER VIEW profile_report_stats OWNER TO postgres;

GRANT SELECT ON profile_report_stats TO authenticated;
