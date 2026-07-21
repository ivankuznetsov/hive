## [2026-07-19T11:15:33Z] Web workflow receipts bind immutable configuration

**Action:** Reconciled Hive Web's two-step install/update/remove lifecycle with
Honeycomb's immutable configuration snapshots. Signed receipts now carry the
reviewed configuration digest alongside package and selected-generation
identity, command adapters reject changed candidate mappings or input bindings,
and the managed store compares source, manifest, and configuration under the
mutation lock. Post-commit cleanup failures remain successful mutations with
visible warnings.

**Why:** A package can keep the same source and manifest while its project
mapping or optional-input binding changes. Applying that configuration after a
different preview would violate the operator's review boundary.

**Security maintenance:** Refreshed the web bundle's vulnerable parser,
sanitizer, networking, concurrency, and WebSocket transitive dependencies to
their patched releases after the configured audit detected current advisories.
