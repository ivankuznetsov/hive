## [2026-06-08T16:07:41Z] wiki — refresh merged finalize error archive coverage

**Action:** Refreshed command/API and helper-module wiki coverage after the daemon-only merged finalize error archive path was added. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "finalize merged error archive pr merge watcher daemon stage_action"` found existing gaps/log context, and the configured master wiki path had no relevant Hive-specific match. Inspected the committed diff plus current `lib/hive/cli.rb`, `lib/hive/commands/stage_action.rb`, `lib/hive/daemon/dispatcher.rb`, `lib/hive/daemon/pr_merge_watcher.rb`, `lib/hive/gh.rb`, and focused daemon/stage-action/GitHub tests. Added [[modules/gh]] as the source-backed home for `Hive::Gh`, documented the internal `hive archive --recover-merged-error-reason` safety gates in [[cli]], [[commands/stage_action]], [[commands/daemon]], [[modules/daemon]], [[state-model]], and [[stages/finalize]], and recorded missing live-daemon smoke evidence in [[gaps]]. Updated [[index]] for the new page count. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/gh]]
- [[index]]
- [[cli]]
- [[commands/stage_action]]
- [[commands/daemon]]
- [[modules/daemon]]
- [[state-model]]
- [[dependencies]]
- [[stages/finalize]]
- [[testing]]
- [[gaps]]
