BEGIN;

-- Share token contract tests（ADR-022，獨立表設計）
-- 結構性驗證：definer/search_path/grants/條件檢查/token 表存取封鎖/trigger。
-- 行為測試（token 有效與否）依賴 auth session context，由 staging synthetic fixture 驗證。

SELECT plan(32);

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
-- Management RPCs must require private visibility（審查 P1 修復）
-- ============================================================
SELECT ok(
  position('= ''private''' in pg_get_functiondef('public.ensure_event_share_token(uuid)'::regprocedure)) > 0,
  'ensure refuses to mint tokens for non-private events'
);

SELECT ok(
  position('= ''private''' in pg_get_functiondef('public.rotate_event_share_token(uuid)'::regprocedure)) > 0,
  'rotate refuses non-private events too'
);

-- ============================================================
-- Resolver: joins the token table and rechecks all event gates
-- ============================================================
SELECT ok(
  pg_get_functiondef('public.get_event_by_share_token(text)'::regprocedure)
    LIKE '%event_share_tokens%',
  'resolver reads tokens from the dedicated table only'
);

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
-- Token table is invisible to every direct access path（審查 P1/P2 修復）
-- ============================================================
SELECT ok(
  (SELECT relrowsecurity FROM pg_class
   WHERE oid = 'public.event_share_tokens'::regclass),
  'event_share_tokens has RLS enabled'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'event_share_tokens'
  ),
  'no RLS policy grants direct access to event_share_tokens'
);

SELECT ok(
  NOT has_table_privilege('anon', 'event_share_tokens', 'SELECT')
    AND NOT has_table_privilege('anon', 'event_share_tokens', 'INSERT')
    AND NOT has_table_privilege('anon', 'event_share_tokens', 'UPDATE')
    AND NOT has_table_privilege('anon', 'event_share_tokens', 'DELETE'),
  'anon has zero table privileges on event_share_tokens'
);

SELECT ok(
  NOT has_table_privilege('authenticated', 'event_share_tokens', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'event_share_tokens', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'event_share_tokens', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'event_share_tokens', 'DELETE'),
  'authenticated has zero table privileges on event_share_tokens'
);

-- ============================================================
-- Capacity resolver for token viewers（ADR-022）
-- ============================================================
SELECT ok(
  (SELECT p.prosecdef FROM pg_proc p
   WHERE p.oid = 'public.get_event_capacity_by_share_token(text)'::regprocedure),
  'capacity-by-token resolver is security definer'
);

SELECT ok(
  (SELECT p.proconfig @> ARRAY['search_path=public, extensions'] FROM pg_proc p
   WHERE p.oid = 'public.get_event_capacity_by_share_token(text)'::regprocedure),
  'capacity-by-token resolver fixes its search path'
);

SELECT ok(
  has_function_privilege('anon', 'public.get_event_capacity_by_share_token(text)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.get_event_capacity_by_share_token(text)', 'EXECUTE'),
  'capacity-by-token resolver is granted to anon and authenticated'
);

SELECT ok(
  pg_get_function_result('public.get_event_capacity_by_share_token(text)'::regprocedure)
    = 'TABLE(approved_registration_count bigint, capacity_external_guest_count bigint)',
  'capacity-by-token resolver matches get_event_capacity output shape'
);

SELECT ok(
  pg_get_functiondef('public.get_event_capacity_by_share_token(text)'::regprocedure)
    LIKE '%event_share_tokens%'
  AND position('= ''private''' in pg_get_functiondef('public.get_event_capacity_by_share_token(text)'::regprocedure)) > 0
  AND pg_get_functiondef('public.get_event_capacity_by_share_token(text)'::regprocedure)
    LIKE '%publication_status = ''published''%',
  'capacity-by-token resolver rechecks token, publication, and private visibility'
);

-- ============================================================
-- Hygiene trigger removes tokens when leaving private visibility
-- ============================================================
SELECT ok(
  EXISTS (
    SELECT 1 FROM information_schema.triggers
    WHERE event_object_schema = 'public'
      AND event_object_table = 'events'
      AND trigger_name = 'trg_delete_share_token_off_private'
  ),
  'leaving private visibility deletes the token row'
);

SELECT ok(
  (SELECT p.prosecdef FROM pg_proc p
   WHERE p.oid = 'public.delete_share_token_off_private()'::regprocedure),
  'hygiene trigger function is security definer'
);

SELECT ok(
  position('publication_status' in pg_get_functiondef('public.delete_share_token_off_private()'::regprocedure)) > 0
    AND position('lifecycle_status' in pg_get_functiondef('public.delete_share_token_off_private()'::regprocedure)) > 0,
  'hygiene deletes tokens on unpublish and draft regression too'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    WHERE c.relname = 'events'
      AND t.tgname = 'trg_delete_share_token_off_private'
      AND pg_get_triggerdef(t.oid) LIKE '%publication_status%'
      AND pg_get_triggerdef(t.oid) LIKE '%lifecycle_status%'
  ),
  'hygiene trigger watches publication and lifecycle columns'
);

SELECT * FROM finish();
ROLLBACK;
