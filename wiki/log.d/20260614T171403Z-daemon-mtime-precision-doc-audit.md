---
date: 2026-06-14
slug: daemon-mtime-precision-doc-audit
pages: [commands/status, state-model, modules/daemon]
---

Refreshed LLM wiki coverage after commit `81b554ac` fixed daemon edit-resume
mtime precision. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "status
mtime precision StatusConsumer"` found existing daemon coverage, and direct wiki
search found adjacent status/state-model wording.

Inspected the committed diff plus current `lib/hive/daemon/status_consumer.rb`,
`lib/hive/daemon/dispatch_baselines.rb`, `lib/hive/commands/status.rb`,
`lib/hive/daemon/concurrency_controller.rb`, `lib/hive/daemon/policy.rb`, and
`test/unit/daemon/status_consumer_test.rb`. Tightened [[commands/status]] and
[[state-model]] so public `tasks[].mtime` remains documented as whole-second
JSON while daemon edit-baseline comparisons are documented as local
`File.mtime(state_file)` re-stats when possible. Adjusted [[modules/daemon]] and
the `DispatchBaselines` source comments so persisted baselines are described as
preserving daemon-local precision, not compensating for an already rounded
comparison input.

No new page was added, so [[index]] page coverage did not change. The existing
[[gaps]] brainstorm-answer-window item still carries the remaining uncertainty;
this refresh did not find additional in-tree evidence beyond the committed
focused unit test and recorded golden-path E2E verification. Did not run
`qmd update` or `qmd embed`, and did not edit compiled [[log]].
