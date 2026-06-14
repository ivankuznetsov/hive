---
date: 2026-06-14
slug: hive-new-commit-lock-audit
pages: [commands/new, modules/lock, modules/git_ops, testing, gaps]
---

Audited commit `bdd9a9fa` after it touched `Hive::Commands::New`, integration
tests, and the `hive new` command wiki. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent [[log]] entries first; `qmd search "hive new commit lock capture git
commit state_home"` surfaced the current `hive new` and commit-lock coverage.

Verified the committed diff and inspected `lib/hive/commands/new.rb`,
`lib/hive/lock.rb`, `lib/hive/git_ops.rb`,
`lib/hive/display_name/generator.rb`, `test/integration/new_test.rb`,
[[commands/new]], [[modules/lock]], [[modules/git_ops]], and [[testing]].
Confirmed the command page already documents the captured-task commit lock and
the focused integration test. Refreshed [[modules/lock]] so the shared lock API
documents the bounded nonblocking flock, macOS/BSD `process_start_time`
fallback, and `hive new` as a commit-lock consumer. Refreshed
[[modules/git_ops]] so `hive_commit` documents scoped staging, optional
pathspec/body/empty-commit arguments, and the caller-owned commit-lock contract.

Recorded remaining uncertainty in [[gaps]]: the capture commit is serialized,
but no in-tree artifact proves the original parallel hivebox Rails/system-worker
failure is fixed end-to-end, and `Hive::DisplayName::Generator#commit_name`
still commits best-effort without taking `Hive::Lock.with_commit_lock`.
Page coverage did not change, so [[index]] needed no catalog update. Did not
run `qmd update` or `qmd embed`.
