## [2026-07-21T22:10:31Z] workflow publish — unify Honeycomb package v1 publication

- Replaced the legacy mutable workflow submission with strict adjacent
  authoring metadata, authored README review sections, one no-follow source
  snapshot, canonical immutable `packages/NAME/VERSION/` bytes, permission
  projection, complete file hashes, and distinct release/package digests.
- Added the pinned Honeycomb lint v1 contract and hermetic redacted analyzer;
  the existing registry manifest and consumer validator remain the package
  compatibility oracle before any remote interaction.
- Added owner-private digest bundles, canonical receipts, per-version locking,
  intent-before-effect direct/fork publication, exact branch/commit/PR reuse,
  current catalogue reconciliation, and explicitly cached offline evidence.
- Upgraded `hive-workflow-publish` to schema v2 with a side-effect-free JSON
  dry-run, exact `--expected-release-digest` confirmation binding, closed
  lifecycle/freshness states, and retry-safe structured errors. The canonical
  Hive operating skill and generated OpenClaw projection consume fields rather
  than prose and forbid merge, approval, force-push, deletion, or catalogue
  mutation.
- Focused unit and integration evidence covers authoring, deterministic package
  validation, lint redaction, retained-state tampering, lost-response resume,
  catalogue/PR lifecycle, schema files, CLI dry-run state isolation, and
  generated skill correspondence. No live GitHub publication, merge, listing,
  Hive release, or ClawHub release was performed.
