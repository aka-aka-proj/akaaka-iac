# 個人黑名單同場確認：本地 TDD 證據

追蹤：aka-aka-proj/akaaka-docs#191；規格 PR：aka-aka-proj/akaaka-docs#214。

- 2026-09-21，從 origin/preview 建立 task worktree。確認 `supabase_db_akaaka-iac` 原不存在後，以此 worktree `supabase db start` 建立；未操作並存的 `akaaka-iac-announce` stack。
- **Red（migration 建立前）**：`supabase test db --local supabase/tests/blocklist_conflict_test.sql` exit 1。舊 single RPC 沒有拋出衝突、反而新增一筆報名；直接 UPDATE approved 亦沒有拋出衝突。新 checked RPC 均為 42883 missing function；私有確認表不存在造成測試結束。當時執行 17 assertions，其中 15 failed，並非 Green 後補跑宣稱 Red。
- **Green**：建立 `20260921001726_registration_blocklist_confirmation.sql` 後，初版 21 assertions 通過；當時全套 31 files / 490 assertions 通過。
- **追加 Red**：已 rejected 的申請直接 UPDATE approved 沒有例外，1/29 failed。補上禁止重新啟用 rejected/cancelled 紀錄後 Green。
- **2026-09-25 回歸**：補充有效／無效 peer 狀態、較後場次衝突回滾較早場次寫入、membership snapshot 改變、容量、跨活動 registration、RPC/table grants 與 blocks owner RLS，40 個黑名單 assertions 通過；全套 31 files / 509 assertions 通過。
- Edge helper 的 boolean consent 與授權 contact metadata：先得到 missing module Red，實作後 2 tests Green；三個 Edge Function 的 Deno check 通過。

以上是本地 SQL／helper 驗證，並不代表 hosted deployment、真實登入瀏覽器或 production release 已驗證。後續以 PR CI、preview deployment 與 issue 驗收紀錄為準。

## 直接 Data API 授權補丁（2026-09-26）

- 在原 migration 的本地資料庫追加不可見活動 INSERT 測試，先得到 Red：41 assertions 中 1 failed，實際 `blocklist_confirmation_required`、預期 `forbidden`。
- 加入先執行的 SECURITY INVOKER 授權 trigger 後 Green；補上可見本人報名仍有提醒及不可假冒其他 profile 的回歸，43 assertions 通過。全套 31 files / 520 assertions 通過。
- 確認原 PR #195 已合併後，將補丁移至由最新 origin/preview 建立的獨立 worktree 與新 migration `20260926005806_authorize_blocklist_conflict_lookup.sql`；不改寫已部署 migration。規格：docs PR #219。

- docs#219 審查追加 eligibility 要求：可見活動的直接 INSERT 仍可在 duplicate 等 constraint 之前探測，先將直接呼叫預期改為 forbidden 取得 Red（1/43 failed）。改為拒絕 anon/authenticated 直接 INSERT 及 pending → approved，統一經完整資格驗證 endpoint；Green 43 assertions、全庫 520 assertions 通過。
