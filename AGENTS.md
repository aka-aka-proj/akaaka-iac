# AkaAka IaC Instructions

- 以繁體中文回覆；所有終端指令均以 `rtk` 為前綴。
- 這是獨立 Git repository；commit 與 push 僅在此目錄執行。
- **Worktree 強制規則：** 每個 coding agent session 必須使用自己的 git worktree 與唯一 task branch，不得在共用 checkout 或直接綁定 `preview` worktree 上修改。開始前執行 `rtk git fetch origin`，再從 `origin/preview` 建立 worktree，例如：`rtk git worktree add -b feat/<task> ../akaaka-iac-feat-<task> origin/preview`。
- Git 版本流程：task branch 只提交並 push 到自己的遠端分支，先建立 task branch → `preview` Pull Request 並合併；不得直接 push `preview`。在 `preview` 驗證通過後，再建立 `preview` → `main` Pull Request，禁止直接 push `main`。Preview IaC 驗證目標為 Supabase project `xdknuxdhyvjgwlcliyqx`；Production 只能由合併後的 `main` 流程部署，並以 GitHub secret 注入 production project ref。
- 任務完成且不再需要 worktree 後，先確認無未提交變更，再執行 `rtk git worktree remove <worktree-path>`；不得移除仍被其他 session 使用的 worktree。
- 進行 AkaAka 功能、修正或架構變更時，先載入 `../.opencode/skills/akaaka-docs/SKILL.md` 並閱讀 `../akaaka-docs/AGENTS.md`，再在 `../akaaka-docs/` 的規格與 ADR 中確認需求；文件必須先於或同步於基礎設施變更更新。
## Supabase 環境與 Anon Key

| 環境 | Supabase URL | Anon Key 檔案 |
|---|---|---|
| **Production** | `https://fkqvjchizknuifjxiawe.supabase.co` | `/home/zacko/Projects/AkaAka/supabase.prod.anon` |
| **Staging** | `https://xdknuxdhyvjgwlcliyqx.supabase.co` | `/home/zacko/Projects/AkaAka/supabase.stage.anon` |

- 操作 Supabase REST API 或驗證 migration 時，從對應的 anon key 檔案讀取 key。
- 變更 Supabase schema、migration、Edge Function 或部署流程後，依 skill 的文件檢查清單確認需更新的文件。
- 不得儲存原始照片；多媒體僅能使用 FB、IG、X.com 的外部社群連結。
- 聲譽系統僅能累積點數，不得扣點；場地方角色升級僅能由管理員手動處理。
