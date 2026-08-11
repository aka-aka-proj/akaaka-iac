-- PostgreSQL table privileges are the Data API gate. RLS policies below still
-- decide which rows and transitions each authenticated user may access.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM authenticated;

-- Controlled backend paths may use the public tables with their own explicit
-- authorization checks. This role is never exposed to the browser. Keep this
-- to DML only; do not grant TRUNCATE, REFERENCES, or TRIGGER privileges.
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.ai_characters,
  public.ai_chat_feedback,
  public.ai_conversations,
  public.ai_messages,
  public.audit_logs,
  public.blocks,
  public.connections,
  public.direct_conversations,
  public.direct_messages,
  public.event_bookmarks,
  public.event_notification_subscriptions,
  public.event_registration_responses,
  public.event_registrations,
  public.event_threads,
  public.events,
  public.issue_comments,
  public.issues,
  public.moderation_actions,
  public.notifications,
  public.profiles,
  public.push_subscriptions,
  public.recommendations,
  public.reports,
  public.user_follows,
  public.user_llm_api_keys
TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_characters TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.ai_chat_feedback TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_conversations TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.ai_messages TO authenticated;
GRANT SELECT ON public.audit_logs TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.blocks TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.connections TO authenticated;
GRANT SELECT ON public.direct_conversations TO authenticated;
GRANT SELECT, INSERT ON public.direct_messages TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.event_bookmarks TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.event_notification_subscriptions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.event_registration_responses TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.event_registrations TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.event_threads TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.events TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.issue_comments TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.issues TO authenticated;
GRANT SELECT, UPDATE ON public.notifications TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.moderation_actions TO authenticated;
GRANT SELECT, INSERT ON public.recommendations TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.reports TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.push_subscriptions TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.user_follows TO authenticated;

-- Column privileges reinforce the field-level boundaries in the RLS matrix.
REVOKE UPDATE ON public.notifications FROM authenticated;
GRANT UPDATE (read_at) ON public.notifications TO authenticated;

-- user_llm_api_keys intentionally receives no browser privilege.
REVOKE ALL ON public.user_llm_api_keys FROM anon, authenticated;
