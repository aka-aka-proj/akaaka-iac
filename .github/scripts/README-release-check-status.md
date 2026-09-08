# Weekly release REST check-status helper

`release-check-status.sh <owner/repo> <commit-sha>` evaluates GitHub Actions check-runs and legacy commit statuses through REST APIs only.

It is intentionally fail-closed: if either check-runs or commit statuses cannot be read, the helper exits non-zero and release readiness remains unknown.

Required token capabilities for repositories evaluated by the weekly release orchestrator:

- repository contents: read/write where the orchestrator merges or persists state
- pull requests: read/write where the orchestrator creates or merges release PRs
- actions: read for workflow/deployment observation
- checks: read for `GET /commits/{sha}/check-runs`
- commit statuses: read for `GET /commits/{sha}/status`

The helper replaces the GraphQL `statusCheckRollup` dependency that failed in scheduled run `33837703022` with `Resource not accessible by personal access token`.
