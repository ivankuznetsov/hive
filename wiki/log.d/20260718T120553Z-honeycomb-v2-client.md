# Honeycomb v2 client contract

**Action:** Replaced the official install reader's legacy nested catalog and
`workflows/NAME/manifest.json` assumptions with canonical
`honeycomb-catalog/v2` flat entries and immutable
`packages/NAME/VERSION/manifest.yml` snapshots. The catalog commit is now the
durable materialization/task-pin identity; review head and upstream source SHA
remain separate audit/provenance identities. Added canonical YAML,
`release_sha256`, complete tree/hash, catalog-binding, lifecycle, update diff,
and task-pin coverage.
The registry manifest uses an absolute `::Digest` lookup so its release check
remains valid after Hive's own `Hive::Digest` namespace is loaded by the full
suite. Hive-version admission also ignores SemVer build metadata, matching
SemVer precedence while remaining compatible with RubyGems version comparison.

**Safety boundary:** Hive only maps the lossless low-risk task-local read-only
v2 disclosure to its exact managed runtime policy. Broader v2 disclosures fail
closed before mutation. Bench and Docs Sync currently resolve/verify but remain
uninstallable, and the existing publish command remains a legacy package
producer.

**Coverage:** Updated [[modules/workflows]], [[commands/workflow]], [[testing]],
[[gaps]], `docs/workflows.md`, and `docs/permissions.md`. Did not edit compiled
[[log]] and did not run `qmd update` or `qmd embed`.
