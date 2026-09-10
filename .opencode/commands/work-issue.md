---
description: Pick one actionable IaC issue, implement it, and finish the PR lifecycle
agent: build
---

Work on `aka-aka-proj/akaaka-iac` and complete one open issue end to end.

Required outcome:

1. Inspect the repository's open GitHub issues.
2. Choose exactly one issue that can be completed now. Prefer a small, high-value item with clear acceptance criteria and no unresolved dependency.
3. Follow `AGENTS.md` before making changes, including the required dedicated worktree and task branch workflow, local validation rules, and relevant AkaAka documentation/spec checks.
4. Read the selected issue and relevant code/docs. When the requirements are clear enough from repository context, proceed without asking the user to choose among equivalent options.
5. Implement the issue completely and keep the diff scoped to that issue. Update tests and documentation when required.
6. Run all relevant local validation required by `AGENTS.md` and fix failures caused by the change. Never bypass hooks or required checks.
7. Commit and push the task branch. Create a Pull Request to `preview`, link the issue, summarize the change, and include validation evidence.
8. Continue handling that PR in the same task:
   - inspect CI/check status and review state;
   - read and address review comments and unresolved threads;
   - make fixes, commit, and push as needed;
   - resolve addressed conversations when possible;
   - rebase/update the branch or resolve merge conflicts when needed;
   - re-check validation after fixes;
   - once all requirements are satisfied, attempt to merge the PR into `preview` using an allowed repository merge method.
9. Creating the PR is not the stopping condition. Finish when the PR is merged, or when a concrete blocker requires user action. If blocked, report the exact blocker and the minimum user action needed.
10. Report the selected issue, PR, implemented changes, validation performed, review/check handling, and merge result.

If several issues are suitable, choose the one with the clearest path to completion instead of asking the user to choose.