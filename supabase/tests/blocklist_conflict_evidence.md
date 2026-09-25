# 個人黑名單同場確認：本地 TDD 證據

追蹤：aka-aka-proj/akaaka-docs#191；規格 PR：aka-aka-proj/akaaka-docs#214。

- 2026-09-21，從 origin/preview 建立 task worktree。確認 `supabase_db_akaaka-iac` 原不存在後，以此 worktree `supabase db start` 建立；未操作並存的 `akaaka-iac-announce` stack。
- **Red（migration 建立前）**：`supabase test db --local supabase/tests/blocklist_conflict_test.sql` exit 1。舊 single RPC 沒有拋出衝突、反而新增一筆報名；直接 UPDATE approved 亦沒有拋出衝突。新 checked RPC 均為 42883 missing function；私有確認表不存在造成測試結束。當時執行 17 assertions，其中 15 failed，並非 Green 後補跑宣稱 Red。
- **Green**：建立 `20260921001726_registration_blocklist_confirmation.sql` 後，初版 21 assertions 通過；當時全套 31 files / 490 assertions 通過。
- **追加 Red**：已 rejected 的申請直接 UPDATE approved 沒有例外，1/29 failed。補上禁止重新啟用 rejected/cancelled 紀錄後 Green。
- **2026-09-25 回歸**：補充有效／無效 peer 狀態、較後場次衝突回滾較早場次寫入、membership snapshot 改變、容量、跨活動 registration、RPC/table grants 與 blocks owner RLS，40 個黑名單 assertions 通過；全套 31 files / 509 assertions 通過。
- Edge helper 的 boolean consent 與授權 contact metadata：先得到 missing module Red，實作後 2 tests Green；三個 Edge Function 的 Deno check 通過。

以上是本地 SQL／helper 驗證，並不代表 hosted deployment、真實登入瀏覽器或 production release 已驗證。後續以 PR CI、preview deployment 與 issue 驗收紀錄為準。
