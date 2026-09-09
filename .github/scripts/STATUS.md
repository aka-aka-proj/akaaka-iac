Implementation status for issue #167:

- REST check/status aggregation helper: complete
- fail-closed API behavior: complete
- regression test script: complete
- token capability documentation: complete
- weekly-production-release.yml wiring: complete

The docs, IaC, and frontend polling loops now invoke the helper with their
already-pinned candidate SHA. Mergeability is read separately through the REST
pull request endpoint. Keep this PR draft until CI and a dry-run succeed.
