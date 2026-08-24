# AkaAka 整體發版順序（Supabase + Vercel）

## 概覽

```
IaC (akaaka-iac, Supabase) -> Backend -> Frontend (Vercel)
```

各層之間仍有依賴關係，但資料層以 Supabase 為主，不使用 AWS。

---

## 詳細流程

### 1. IaC 層（本 Repo）

**目標**：管理 Supabase schema/migrations 與 Edge Functions  
**Repo**：`aka-aka-proj/akaaka-iac`

| 步驟 | 說明 |
|------|------|
| PR CI | 檢查 `supabase/migrations` 與 `supabase/functions` |
| Main CD | `supabase db push` -> deploy Supabase Edge Functions |

Main CD 使用既有 hosted migration history 逐一比對；`supabase/migrations/`
必須保留 production 已套用的每個 timestamp 檔案，新的 schema 變更才可在
較新的 timestamp migration 中發布。不得在沒有 migration-history repair
計畫時，將既有 migration 直接 squash 成單一 baseline。

**產出物**：
- Supabase schema 變更
- Supabase Edge Functions 最新部署版本

#### Web Push delivery 部署順序

`deliver-web-push` 是由 GitHub Actions scheduler 呼叫的受控 Edge Function。部署
Web Push slice 時，必須依下列順序完成：缺少 VAPID／Supabase 執行期設定時，
function 會回傳 HTTP 500 `delivery_not_configured`；缺少或不符的
`PUSH_DELIVERY_TOKEN` 則會在授權檢查階段直接回傳 HTTP 401 `unauthorized`，
不會進到 VAPID 設定檢查。任一非 200 response 都會使 scheduler run 失敗：

1. 在目標 Supabase project 的 Edge Function secrets 設定四個必要值：
   `VAPID_SUBJECT`、`VAPID_PUBLIC_KEY`、`VAPID_PRIVATE_KEY`、
   `PUSH_DELIVERY_TOKEN`。
2. 完成 schema／function 的 IaC CD，確認 `deliver-web-push` 已部署至同一個
   project ref。
3. 設定 repository 層級的 GitHub Actions scheduler secrets（`Settings ->
   Secrets and variables -> Actions`）。`.github/workflows/web-push-delivery-scheduler.yml`
   的 `deliver` job 未綁定任何 GitHub Actions environment，environment secrets
   無法被排程與手動 smoke 讀取，因此四項值不得設定為 environment secrets。
   確認 `SUPABASE_PROJECT_REF` 與 `PUSH_DELIVERY_TOKEN` 指向同一個 production
   project；preview smoke 則使用 `SUPABASE_PROJECT_REF_PREVIEW` 與
   `PUSH_DELIVERY_TOKEN_PREVIEW`。
4. 在 `preview` 以 `workflow_dispatch` 執行 staging smoke；確認 HTTP 200 且
   response 僅包含安全的 delivery summary 後，才可將變更合併至 `main`。
5. `main` 上的 `schedule` 每 5 分鐘執行 production delivery；不得在
   `preview` 或其他分支啟用排程。部署成功不等於 provider 已實際送達，仍須
   依 Web Push runbook 留存正常 scheduler run 的 runtime evidence。

VAPID 三項 secrets 只供 Edge Function runtime 使用；scheduler 不得取得或注入
VAPID key。`PUSH_DELIVERY_TOKEN` 必須在 Edge Function 與 workflow 依 branch
選擇的 scheduler secret（production 或 preview 配對）使用相同值，但 production
與 preview 必須分開。所有 secret value 不得提交 repository、issue、workflow
log、summary 或 response。

---

### 2. Backend 層

**目標**：部署 API server / worker  
**前置條件**：Supabase schema 與 functions 已更新完成

建議在 backend workflow 中等待 IaC CD 成功後觸發部署，確保 API 與資料庫 schema 相容。

---

### 3. Frontend 層（Vercel）

**目標**：部署前端應用（Vercel）  
**前置條件**：Backend 已部署、Supabase 端點可用

建議由 frontend workflow（或 Vercel Git Integration）在 backend 完成後再進行正式環境發布。

---

## 環境映射

| Git 分支 | Supabase 專案 | Frontend 平台 |
|----------|----------------|---------------|
| `main`   | production project | Vercel production |
| feature/PR | preview or staging project（依團隊策略） | Vercel preview |

---

## 緊急回滾

1. 找到上一個可用 commit SHA  
2. 回滾 `supabase/migrations` 與/或 `supabase/functions` 變更  
3. 重新觸發 `iac-cd.yml`（push main 或 workflow_dispatch）

---

## Secrets

### IaC CD 的 GitHub Secrets

| Secret 名稱 | 用途 |
|-------------|------|
| `SUPABASE_ACCESS_TOKEN` | Supabase CLI 驗證 |
| `SUPABASE_PROJECT_REF` | 指定目標 Supabase 專案 |
| `SUPABASE_DB_PASSWORD` | `supabase db push` 需要時使用 |

### `deliver-web-push` 的 Supabase Edge Function secrets

以下四項都是 production 執行前置條件；preview/staging 也必須在 staging
project 設定對應的獨立值：

| Secret 名稱 | 儲存位置 | 用途 |
|-------------|----------|------|
| `VAPID_SUBJECT` | Supabase Edge Function runtime | Web Push VAPID subject |
| `VAPID_PUBLIC_KEY` | Supabase Edge Function runtime | Web Push VAPID public key |
| `VAPID_PRIVATE_KEY` | Supabase Edge Function runtime | Web Push VAPID signing private key |
| `PUSH_DELIVERY_TOKEN` | Supabase Edge Function runtime | 驗證 scheduler 的 Bearer token |

### Web Push scheduler 的 GitHub Secrets

`.github/workflows/web-push-delivery-scheduler.yml` 依 branch 選擇下列配對；兩
者必須指向同一個 Supabase project：

| GitHub Secret 名稱 | 使用情境 | 用途 |
|--------------------|----------|------|
| `SUPABASE_PROJECT_REF` | `main` production | production project ref |
| `PUSH_DELIVERY_TOKEN` | `main` production | 呼叫 production Edge Function |
| `SUPABASE_PROJECT_REF_PREVIEW` | `preview` manual smoke | staging project ref |
| `PUSH_DELIVERY_TOKEN_PREVIEW` | `preview` manual smoke | 呼叫 staging Edge Function |

`schedule` 僅在 `main` 執行；`workflow_dispatch` 可在 `preview` 執行 staging
smoke，也可在 `main` 執行 production run。scheduler 只注入對應環境的
`PUSH_DELIVERY_TOKEN`，不注入 VAPID secrets。
