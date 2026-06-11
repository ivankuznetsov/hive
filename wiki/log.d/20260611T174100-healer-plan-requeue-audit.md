---
date: 2026-06-11
slug: healer-plan-requeue-audit
pages: [architecture, modules/daemon, state-model, stages/plan, modules/task_action, testing, gaps]
---

Post-commit audit for `5f7ba051` (`fix(daemon): healer requeues 3-plan
reruns instead of deadlocking`). Read `AGENTS.md`, `.llm-wiki/config.json`,
[[index]], [[decisions]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "stale agent healer 3-plan dispatch request heal_requeued"`
returned no indexed hits, and the configured master wiki path had no matching
healer/requeue context.

Inspected the committed diff plus current
`lib/hive/daemon/stale_agent_healer.rb`, `lib/hive/daemon/logger.rb`,
`lib/hive/daemon/dispatch_request_queue.rb`, `lib/hive/task_action.rb`,
`test/unit/daemon/stale_agent_healer_test.rb`, and
`test/integration/daemon_stale_agent_healing_test.rb`. Corrected stale wiki
coverage, including [[architecture]], that still described terminal agent-loss
auto-clears as late-stage-only: the current healer covers every non-review stage
(`2-brainstorm`, `3-plan`, `4-execute`, `7-artifacts`, `8-finalize`), while
`3-plan` additionally queues `hive plan <slug> --project <project> --from
3-plan` with `requestor=healer` / `trigger=terminal_agent_loss` because an
empty markerless `plan.md` otherwise remains an undispatchable `:error`.

During source verification, found that `StaleAgentHealer` emitted
`heal_requeued` but the closed daemon log enum did not include it. Added the
enum entry and the integration closed-enum assertion so the documented trace
event is accepted by the real logger. Recorded the remaining uncertainty in
[[gaps]]: no in-tree live artifact proves a real daemon observes a red
`3-plan` terminal-agent-loss row, writes the queue request, dispatches it, and
surfaces recovery or bounded exhaustion. Verified with
`bundle exec ruby -Itest test/unit/daemon/stale_agent_healer_test.rb test/integration/daemon_stale_agent_healing_test.rb`
and `bundle exec rubocop --format simple lib/hive/daemon/logger.rb
test/integration/daemon_stale_agent_healing_test.rb`. Page coverage did not
change, so [[index]] did not need a catalog update. Did not run `qmd update`
or `qmd embed`.
