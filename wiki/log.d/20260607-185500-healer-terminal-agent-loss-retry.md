## [2026-06-07T18:55:00Z] daemon — retry late-stage terminal agent-loss errors

**Action:** Extended `Hive::Daemon::StaleAgentHealer` so late-stage terminal agent-loss errors are recovered by the normal daemon flow instead of staying red after ordinary interruptions. `7-artifacts` and `8-finalize` rows with `ERROR reason=tmux_session_terminated` or `ERROR reason=agent_orphaned` now clear when no live task lock exists, using the same marker-id guard, pre-clear dispatch-baseline seeding, bounded per-process retry budget, and one-shot `marker_heal_exhausted` logging used by finalize `ERROR reason=unpushed_commits`. The healer logs these retries as `reason=terminal_agent_loss`, keeps the original marker reason in `marker_reason`, and leaves repository-state/manual failures such as `ERROR reason=git_status_failed` red for operator inspection. Added focused tests for artifacts tmux-session loss, finalize orphaned-agent loss, marker-id races, live-lock skips, git-status manual skips, and retry-budget exhaustion, then refreshed daemon, artifacts, finalize, testing, and gaps docs.

**Tests:**
- `bundle exec ruby -Itest test/unit/daemon/stale_agent_healer_test.rb`

**Refreshed pages:**
- [[modules/daemon]]
- [[stages/artifacts]]
- [[stages/finalize]]
- [[testing]]
- [[gaps]]
