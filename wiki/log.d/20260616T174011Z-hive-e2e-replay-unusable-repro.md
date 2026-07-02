---
date: 2026-06-16
slug: hive-e2e-replay-unusable-repro
pages: [commands, e2e, testing, gaps]
---

Refreshed command/API and executable-entrypoint wiki coverage after commit
`cb986b33` changed `bin/hive-e2e` and
`test/e2e/lib/hive_e2e_binary_test.rb`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent compiled [[log]] entries first. `qmd search "hive-e2e replay
unusable_repro non executable repro"` returned no indexed hits, and the
configured master wiki path had no matching `hive-e2e` / `repro.sh` context, so
verification used the committed diff plus direct source and wiki reads.

Documented that `bin/hive-e2e replay RUN_ID SCENARIO` now validates the stored
`repro.sh` as a regular executable file before the no-shell `exec`. Missing
repro scripts still report `missing_repro`; existing but non-executable or
otherwise non-regular scripts report `unusable_repro`; both are config failures
with exit `78` and `hive-e2e-error` JSON envelopes when `--json` is requested.
Refreshed [[commands]], [[e2e]], and [[testing]], and carried forward the
uncertainty in [[gaps]]: the new path is focused-test pinned, but no in-tree
artifact shows a live patrol/babysitter wrapper consuming the
`unusable_repro` replay error. Page coverage did not change, so [[index]] did
not need a catalog update. Did not run `qmd update` or `qmd embed`.
