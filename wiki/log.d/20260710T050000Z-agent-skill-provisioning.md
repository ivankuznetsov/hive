## [2026-07-10T05:00:00Z] agents - provision enabled built-in skills

**Action:** Added the packaged `config/agent-skills.yml` source of truth, strict
default-coverage validation, effective target resolution, and one shared
evidence-rich inspector for Claude, Codex, and Pi. `hive doctor` is read-only
and now emits `hive-doctor.v2`; `hive setup-agents` previews one aggregate
native-operation plan, enforces consent, revalidates ownership/state, continues
independent operations, and post-verifies with `hive-setup-agents.v1` automation
output. Interactive init may delegate to the same setup engine after project
creation while JSON/non-TTY init remains non-mutating.

**Safety and coverage:** Native adapters preserve user-owned Codex sources,
unrelated TOML bytes/mode, concurrent edits, and user-authored Claude `/plan`
aliases. Process-level fake CLI acceptance covers fresh convergence, no-op
reruns, conflicts, unavailable agents, unattended consent, and partial failure.
Authenticated provider activation remains opt-in through disposable-home smoke
tests. Updated [[commands/doctor]], [[commands/setup-agents]], [[commands/init]],
[[modules/agent_profile]], [[testing]], and [[gaps]]; did not edit compiled
[[log]].
