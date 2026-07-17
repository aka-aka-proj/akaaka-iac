# akaaka-iac

AkaAka 專案的資料層基礎設施設定倉庫。  
本 repo 目前以 **Supabase + Vercel** 為唯一部署主流程，不使用 AWS。

```
IaC (本 repo, Supabase) -> Backend -> Frontend (Vercel)
```

---

## 目錄結構

```
.
|-- .github/workflows/
|   |-- iac-ci.yml          # PR CI: 檢查 supabase/migrations 與 supabase/functions
|   `-- iac-cd.yml          # main CD: supabase db push -> deploy functions
|-- docs/
|   `-- release-order.md    # 整體發版順序說明
|-- supabase/
|   |-- migrations/         # SQL migrations
|   `-- functions/          # Supabase Edge Functions
`-- terraform/              # Legacy (非主部署流程，僅保留歷史參考)
```

---

## CI/CD 流程

### PR CI（`iac-ci.yml`）

觸發條件：PR 到 `main` 且變更包含：
- `supabase/migrations/**`
- `supabase/functions/**`

檢查內容：
- `supabase/migrations` 路徑存在，且 migration 檔名符合 `YYYYMMDDHHMMSS_description.sql`
- `supabase/functions` 路徑存在，且每個 function 目錄至少有 `index.ts` 或 `index.js`

### Main CD（`iac-cd.yml`）

觸發條件：
- push 到 `main` 且變更包含 `supabase/migrations/**` 或 `supabase/functions/**`
- 或手動 `workflow_dispatch`

部署順序：
1. `supabase db push`
2. 逐一 deploy `supabase/functions/*` 下的 functions

---

## GitHub Secrets 設定

請在 Repo `Settings -> Secrets and variables -> Actions` 建立以下 Secrets：

| Secret 名稱 | 必要性 | 用途 |
|-------------|--------|------|
| `SUPABASE_ACCESS_TOKEN` | 必填 | Supabase CLI 驗證 |
| `SUPABASE_PROJECT_REF` | 必填 | 指定部署目標 Supabase 專案 |
| `SUPABASE_DB_PASSWORD` | 選填 | `supabase db push` 在需要密碼時使用 |

---

## 本地開發（Supabase）

```bash
npm i -g supabase
supabase login
supabase link --project-ref <your-project-ref>
supabase db push
supabase functions deploy <function-name> --project-ref <your-project-ref>
```

---

## Legacy 說明

`terraform/` 目錄保留舊版內容供歷史追蹤，不是現行部署管線。  
目前正式流程僅支援 Supabase（資料層）與 Vercel（前端託管）。

---

## 相關文件

- [整體發版順序](./docs/release-order.md)
- [Supabase CLI 文件](https://supabase.com/docs/reference/cli)
- [Vercel 文件](https://vercel.com/docs)
