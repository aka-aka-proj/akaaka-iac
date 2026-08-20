# AkaAka IaC Instructions

- 以繁體中文回覆；所有終端指令均以 `rtk` 為前綴。
- 這是獨立 Git repository；commit 與 push 僅在此目錄執行。
- Git 版本流程：所有變更先 checkout／同步 `preview`，只提交並 push 到 `preview`；驗證通過後建立 `preview` → `main` Pull Request，禁止直接 push `main`。Preview IaC 驗證目標為 Supabase project `xdknuxdhyvjgwlcliyqx`；Production 只能由合併後的 `main` 流程部署，並以 GitHub secret 注入 production project ref。
- 進行 AkaAka 功能、修正或架構變更時，先載入 `../.opencode/skills/akaaka-docs/SKILL.md` 並閱讀 `../akaaka-docs/AGENTS.md`，再在 `../akaaka-docs/` 的規格與 ADR 中確認需求；文件必須先於或同步於基礎設施變更更新。
## Supabase 環境與 Anon Key

| 環境 | Supabase URL | Anon Key 檔案 |
|---|---|---|
| **Production** | `https://fkqvjchizknuifjxiawe.supabase.co` | `/home/zacko/Projects/AkaAka/supabase.prod.anon` |
| **Staging** | `https://xdknuxdhyvjgwlcliyqx.supabase.co` | `/home/zacko/Projects/AkaAka/supabase.stage.anon` |

## Supabase DB Password

執行 `supabase db push` 部署 migration 到遠端資料庫時需要 DB password（不同於 anon key）：

| 環境 | DB Password 檔案 |
|---|---|
| **Production** | `/home/zacko/Projects/AkaAka/supabase.db.pwd.prod` |
| **Staging** | `/home/zacko/Projects/AkaAka/supabase.db.pwd.stage` |

進入 `akaaka-iac/` 目錄時 `direnv` 會自動載入 `SUPABASE_DB_PASSWORD`（staging），直接執行 `supabase db push` 即可。若需部署 production，手動切換：
```bash
export SUPABASE_DB_PASSWORD="$(cat /home/zacko/Projects/AkaAka/supabase.db.pwd.prod)"
supabase db push
```

- 操作 Supabase REST API 或驗證 migration 時，從對應的 anon key 檔案讀取 key。
- 變更 Supabase schema、migration、Edge Function 或部署流程後，依 skill 的文件檢查清單確認需更新的文件。
- 不得儲存原始照片；多媒體僅能使用 FB、IG、X.com 的外部社群連結。
- 聲譽系統僅能累積點數，不得扣點；場地方角色升級僅能由管理員手動處理。
