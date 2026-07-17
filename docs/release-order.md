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

**產出物**：
- Supabase schema 變更
- Supabase Edge Functions 最新部署版本

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

IaC workflow 需使用以下 GitHub Secrets：

| Secret 名稱 | 用途 |
|-------------|------|
| `SUPABASE_ACCESS_TOKEN` | Supabase CLI 驗證 |
| `SUPABASE_PROJECT_REF` | 指定目標 Supabase 專案 |
| `SUPABASE_DB_PASSWORD` | `supabase db push` 需要時使用 |
