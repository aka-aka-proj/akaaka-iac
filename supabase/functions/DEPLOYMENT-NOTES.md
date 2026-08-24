# Edge Function Deployment Notes

追蹤需要跨部署階段協調的行為切換；規範依據見 `akaaka-docs/docs/spec/features/events/007-recurring-events-spec.md`（以下稱 spec 007）。

## create-recurring-events — recurrence 新驗證相容期

- **狀態**：相容期開啟中（`supabase/functions/_shared/recurrence.ts` 的 `LEGACY_PAYLOAD_COMPAT_ENABLED = true`）。
- **起始**：2026-08-24，PR aka-aka-proj/akaaka-iac#52（含後續 stacked 分支）部署至 production 時生效。
- **相容期內行為**（spec 007「部署相容期」第 1 階段）：
  - 舊型 payload（無 `timezone`、`count` 必填、`until` 可選且可與 `count` 併存）→ 施以舊契約驗證，語義為先以 `until` 過濾、再以 `count` 截斷；日曆運算使用 UTC。
  - 新型 payload（含 `timezone`）→ 施以完整新驗證：`timezone` 必須為有效 IANA 名稱、`count`／`until` 恰好擇一、各模式欄位白名單、系列總場次數上限 52（超過回 `400 validation_error`）、日曆運算以 `timezone` 為基準。
- **結束條件**：新版前端（送出 `recurrence_rule.timezone`）已在 production 驗證後，將 `LEGACY_PAYLOAD_COMPAT_ENABLED` 改為 `false` 並刪除本節。屆時舊型 payload 將因缺 `timezone` 被拒。
- **待決文件修訂（TBD）**：spec 007「日期演算法」第 2 步的「ISO 週（週一為一週之始）」文字與既有共同測試向量（V1、V2：週日基準＋間隔 ≥2 的期望序列）不一致；實作與向量一致採「包含原始活動當地日期之週（週日起算）內、各選定星期取嚴格晚於基準的首個出現，其後每 `interval` 週遞移」。需以 ADR 或 spec 修訂擇一收斂（追蹤：akaaka-docs issue）。
