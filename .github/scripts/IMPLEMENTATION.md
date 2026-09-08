Issue #167 implementation scope:

- eliminate GraphQL `statusCheckRollup` from weekly release gating
- use REST check-runs + commit status APIs
- fail closed on API read errors
- preserve merge-state/conflict logic separately
- keep strict ordering, manifest pinning, CAS merge, deployment monitoring, checkpoint semantics, and resume behavior unchanged
