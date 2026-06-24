## [2026-06-19T23:17:59Z] task — workflow descriptor resolution

**Action:** Implemented U3 of the workflow-as-data inversion. `Hive::Workflow`
now exposes stage lookup helpers, `TaskMeta.read` surfaces a read-only
`workflow:` selector, and `Config::DEFAULTS` includes
`default_workflow: "coding"`. `Hive::Task` resolves a descriptor through
task selector -> project default -> coding, validates both stage name and
numeric prefix against that descriptor, and derives `state_file` from the
selected workflow. `Hive::Commands::Run#pick_runner` now passes
`task.workflow` to `Hive::Stages::Resolver`, so non-coding agent stages dispatch
through their own descriptor while field-less coding tasks keep historical
state-file paths and runners.

**Tests:** Added focused unit coverage for workflow lookups, meta selector
reads, default workflow config, descriptor-driven task validation/fallbacks,
unknown workflow reclassification as `InvalidTaskPath`, and run-path dispatch
using a throwaway research descriptor. Updated [[modules/task]],
[[state-model]], [[modules/config]], [[modules/workflows]], [[commands/run]],
and [[testing]].
