# AkaAka deletion ledger Worker

This is the stage-only independent deletion ledger provider for Issue #78.

- authoritative storage: one SQLite-backed Durable Object
- API: server-to-server only
- accepted data: opaque deletion metadata only
- `LEDGER_AUTH_TOKEN`: Worker secret; never commit or log its value
- `LEDGER_MODE=stage`: fail closed unless explicitly enabled
- `LEDGER_RETENTION_DAYS=90`: scheduled metadata-only cleanup window; only verified records older than the window are eligible
- the cron trigger performs bounded retention maintenance and a metadata-only health check; it must not auto-approve restore cutover
- cleanup examines at most 100 verified records per invocation; recorded, applied and failed records are protected

Cloudflare KV is not an authoritative ledger because eventual consistency is insufficient for idempotent lifecycle transitions.
