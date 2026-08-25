# Edge Function Deployment Notes

追蹤需要跨部署階段協調的行為切換；規範依據見 `akaaka-docs/docs/spec/features/events/007-recurring-events-spec.md`（以下稱 spec 007）。

## create-recurring-events — recurrence 新驗證相容期（已結束）

- **狀態**：**相容期已結束**（結束日期：2026-08-25）。舊型 payload 相容路徑（原 `LEGACY_PAYLOAD_COMPAT_ENABLED`）已自 `_shared/recurrence.ts` 移除，所有 payload 一律走嚴格驗證。
- **期間**：2026-08-24 開始（PR aka-aka-proj/akaaka-iac#52 含後續 stacked 分支部署至 production 時生效）；2026-08-25 結束（issue aka-aka-proj/akaaka-iac#65）。
- **結束依據**：
  - 前端時區化已隨 aka-aka-proj/akaaka-frontend#66 完成，並經 #67、#74 release 進入 production main（2026-08-24T18:36Z 合併）。
  - Production 實證檢查（2026-08-25）：以 Supabase REST API 掃描 production `events` 表，無任何循環事件（`recurrence_rule` 非 null 者為 0 筆），確認相容期內沒有舊型 payload 的實際使用。未驗證範圍：draft 狀態活動對 anon key 不可見。
- **切換後行為**（spec 007「部署相容期」第 2 階段）：所有 payload 施以完整新驗證——`timezone` 必填且須為有效 IANA 名稱、`count`／`until` 恰好擇一、各模式欄位白名單、系列總場次上限 52；舊型 payload（缺 `timezone`、或 `count`+`until` 並存）回 `400 validation_error`。
- **歷史備註（已結案）**：spec 007「日期演算法」第 2 步的每週錨定文字修訂已完成——決策見 ADR 020（akaaka-docs#113，修訂 PR #116）。
