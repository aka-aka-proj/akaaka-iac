# Weekly release REST gate wiring

The remaining workflow integration is deliberately narrow. Replace the three `statusCheckRollup` polling loops in `.github/workflows/weekly-production-release.yml` (docs, IaC, frontend) with calls to `.github/scripts/release-check-status.sh`, while keeping merge-state/conflict checks separate.

Each loop should:

1. Resolve the exact candidate head SHA already pinned by the release manifest.
2. Run the REST helper and fail closed if it exits non-zero.
3. Read `.failed` and `.pending` from the helper JSON.
4. Keep the existing `mergeStateStatus`/conflict handling independently.
5. Preserve the current deadlines, strict ordering, CAS merge, checkpoint, and resume behavior unchanged.

This file is temporary implementation guidance and should be removed when the workflow wiring is complete.
