# AkaAka deletion ledger Worker

This is the stage-only independent deletion ledger provider for Issue #78.

- authoritative storage: one SQLite-backed Durable Object
- API: server-to-server only
- accepted data: opaque deletion metadata only
- `LEDGER_AUTH_TOKEN`: Worker secret; never commit or log its value
- `LEDGER_MODE=stage`: fail closed unless explicitly enabled
- the current cron trigger performs only a metadata-only health check; bounded provider retry/reconciliation is a later slice and must not auto-approve restore cutover

Cloudflare KV is not an authoritative ledger because eventual consistency is insufficient for idempotent lifecycle transitions.
