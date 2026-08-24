# akaaka-iac

AkaAka 專案的資料層基礎設施設定倉庫。  
本 repo 目前以 **Supabase + Vercel** 為唯一部署主流程

```
IaC (本 repo, Supabase) -> Backend -> Frontend (Vercel)
```

---

## 目錄結構

```
.
|-- .github/workflows/
|   |-- iac-ci.yml          # PR CI: 檢查 supabase/migrations 與 supabase/functions
|   `-- iac-cd.yml          # main CD: merge preview -> main 後 db push -> deploy functions
|-- docs/
|   `-- release-order.md    # 整體發版順序說明
|-- supabase/
|   |-- migrations/         # SQL migrations
|   `-- functions/          # Supabase Edge Functions
```

---

## CI/CD 流程

### PR CI（`iac-ci.yml`）

觸發條件：PR 到 `main` 且變更包含：
- `supabase/migrations/**`
- `supabase/tests/**`
- `supabase/functions/**`

檢查內容：
- `supabase/migrations` 路徑存在，且 migration 檔名符合 `YYYYMMDDHHMMSS_description.sql`
- `supabase/tests` 下所有 `.sql`（含子目錄）皆為本地 pgTAP 契約測試：在本地 Supabase 逐一執行 `supabase test db --local <file>`，任一套件失敗即擋下 PR
- `supabase/functions` 路徑存在，且每個可部署 function 目錄至少有 `index.ts` 或 `index.js`；`_shared` 為共用模組，不是可部署 function

### Preview → Main 發版流程

- 所有 IaC 變更先在 `preview` 分支提交與推送。
- Preview 分支只使用 Supabase project `xdknuxdhyvjgwlcliyqx` 做驗證；project ref 不寫入 secret 以外的部署設定。
- 驗證通過後建立 `preview` → `main` PR；禁止直接 push `main`。

### Main CD（`iac-cd.yml`）

觸發條件：
- `preview` → `main` PR 合併後 push 到 `main`，且變更包含 `supabase/migrations/**` 或 `supabase/functions/**`
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

## 相關文件

- [整體發版順序](./docs/release-order.md)
- [Supabase CLI 文件](https://supabase.com/docs/reference/cli)
- [Vercel 文件](https://vercel.com/docs)
