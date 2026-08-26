# Daemon E2E display-name backfill no longer leaks child processes

**Date:** 2026-08-23
**Scope:** `test/support/daemon_e2e_harness.rb`,
`test/integration/content_workflow_e2e_test.rb`

The in-process daemon E2E harness now injects an inline spawn collaborator for
`DisplayNameBackfiller`. It still exercises the real backfill projection and
asserts that every content-workflow stage requests name generation, but models
the inflight child with the current process pid instead of starting detached
`hive generate-name` commands.

Previously the content workflow E2E started one real name-generation child at
each stage transition. Those children inherited coverage collection and could
finish after Minitest wrote its shard manifest, making the strict aggregate gate
correctly reject an extra process result even though all tests passed. Daemon
production behavior is unchanged; only the process-local E2E boundary changed.
