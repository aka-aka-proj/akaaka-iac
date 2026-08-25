BEGIN;

-- Share token contract tests（ADR-022）
-- 結構性驗證：definer/search_path/grants/條件檢查/欄位權限/index/trigger。
-- 行為測試（token 有效與否）依賴 auth session context，由 staging synthetic fixture 驗證。

SELECT plan(20);

-- ============================================================
-- SECURITY DEFINER + fixed search_path
-- ============================================================
SELECT ok(
  (SELECT p.prosecdef FROM pg_proc p
   WHERE p.oid = 'public.ensure_event_share_token(uuid)'::regprocedure),
  'ensure_event_share_token is security definer'
);

SELECT ok(
  (SELECT p.proconfig @> ARRAY['search_path=public, extensions'] FROM pg_proc p
   WHERE p.oid = 'public.ensure_event_share_token(uuid)'::regprocedure),
  'ensure_event_share_token fixes its search path'
);

SELECT ok(
  (SELECT p.prosecdef FROM pg_proc p
   WHERE p.oid = 'public.rotate_event_share_token(uuid)'::regprocedure),
  'rotate_event_share_token is security definer'
);

SELECT ok(
  (SELECT p.proconfig @> ARRAY['search_path=public, extensions'] FROM pg_proc p
   WHERE p.oid = 'public.rotate_event_share_token(uuid)'::regprocedure),
  'rotate_event_share_token fixes its search path'
);

SELECT ok(
  (SELECT p.prosecdef FROM pg_proc p
   WHERE p.oid = 'public.get_event_by_share_token(text)'::regprocedure),
  'get_event_by_share_token is security definer'
);

SELECT ok(
  (SELECT p.proconfig @> ARRAY['search_path=public, extensions'] FROM pg_proc p
   WHERE p.oid = 'public.get_event_by_share_token(text)'::regprocedure),
  'get_event_by_share_token fixes its search path'
);

-- ============================================================
-- Grants: management RPCs are owner-side (authenticated only)
-- ============================================================
SELECT ok(
  NOT has_function_privilege('anon', 'public.ensure_event_share_token(uuid)', 'EXECUTE'),
  'anon cannot manage share tokens'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.ensure_event_share_token(uuid)', 'EXECUTE'),
  'authenticated hosts can ensure a share token'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.rotate_event_share_token(uuid)', 'EXECUTE'),
  'anon cannot rotate share tokens'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.rotate_event_share_token(uuid)', 'EXECUTE'),
  'authenticated hosts can rotate a share token'
);

SELECT ok(
  has_function_privilege('anon', 'public.get_event_by_share_token(text)', 'EXECUTE'),
  'anonymous link holders can resolve a share token'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.get_event_by_share_token(text)', 'EXECUTE'),
  'authenticated link holders can resolve a share token'
);

-- ============================================================
-- Resolver must recheck publication / lifecycle / visibility / blocks
-- ============================================================
SELECT ok(
  pg_get_functiondef('public.get_event_by_share_token(text)'::regprocedure)
    LIKE '%publication_status = ''published''%',
  'resolver rechecks publication status'
);

SELECT ok(
  pg_get_functiondef('public.get_event_by_share_token(text)'::regprocedure)
    LIKE '%lifecycle_status <> ''draft''%',
  'resolver excludes drafts'
);

SELECT ok(
  pg_get_functiondef('public.get_event_by_share_token(text)'::regprocedure)
    LIKE '%visibility_settings%',
  'resolver rechecks private visibility'
);

SELECT ok(
  pg_get_functiondef('public.get_event_by_share_token(text)'::regprocedure)
    LIKE '%public.blocks%',
  'resolver suppresses blocked relationships'
);

-- ============================================================
-- Column hardening: no direct UPDATE of events.share_token
-- （SELECT 維持開放，避免破壞既有 SELECT * 讀取路徑；可見者讀取
-- token 不會獲得超出其 RLS 的任何權限。）
-- ============================================================
SELECT ok(
  NOT has_column_privilege('anon', 'events', 'share_token', 'UPDATE'),
  'anon cannot update events.share_token directly'
);

SELECT ok(
  NOT has_column_privilege('authenticated', 'events', 'share_token', 'UPDATE'),
  'authenticated users cannot update events.share_token directly'
);

-- ============================================================
-- Index + visibility-change hygiene trigger
-- ============================================================
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'events'
      AND indexname = 'idx_events_share_token'
  ),
  'partial unique index backs share tokens'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.triggers
    WHERE event_object_schema = 'public'
      AND event_object_table = 'events'
      AND trigger_name = 'trg_clear_share_token_off_private'
  ),
  'leaving private visibility clears the share token'
);

SELECT * FROM finish();
ROLLBACK;
