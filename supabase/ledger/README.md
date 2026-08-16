# Independent deletion ledger bootstrap

This directory contains the schema bootstrap for the independent deletion ledger project.

It is intentionally outside `supabase/migrations/` and must not be applied to the
AkaAka application project. Apply it only to the separately provisioned stage or
production ledger project after the owner/security approval recorded in Issue #78.

The bootstrap is metadata-only. It does not contain application ciphertext,
wrapped keys, provider secrets, prompts, completions, or memory fields.
