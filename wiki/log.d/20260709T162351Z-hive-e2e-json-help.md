## [2026-07-09T16:23:51Z] e2e — leading JSON command-help coverage

**Action:** Refreshed command/API wiki coverage for branch HEAD after it changed
`bin/hive-e2e` normalization around leading JSON flags and command help. Read
`AGENTS.md`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent
[[log]] entries first; `qmd search "hive-e2e replay help leading JSON"` found
no indexed project-wiki hits, and the configured main wiki path was unavailable
in this sandbox, so verification used direct wiki/source reads. Inspected the
committed diff plus current `bin/hive-e2e` and
`test/e2e/lib/hive_e2e_binary_test.rb`. Documented that leading-JSON command
help (`--json --help run` and `--json -h run`) now drops the irrelevant JSON
flag and renders human `run` help with exit `0`, while non-command help
trailers still restore the JSON path so usage/no-scenarios failures emit
`hive-e2e-error`. Carried forward the uncertainty that this checkout-only
harness behavior is source/test-pinned, not live-smoked through patrol or
babysitter wrappers. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands]]
- [[e2e]]
- [[testing]]
- [[gaps]]
