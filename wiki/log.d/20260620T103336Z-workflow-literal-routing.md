## workflow - U6 descriptor-routed stage literal consumers

**Action:** Routed the generic workflow daemon path and hardcoded stage-literal
consumers through descriptor-aware seams, while keeping coding-only behavior
explicit:
- Added `Hive::Workflow#has_stage?`, live `Hive::Workflows::Registry.all` /
  `.ids`, and `Hive::Workflows.all_stage_dirs` / `.all_stage_names` for
  descriptor-aware scans without changing coding's load-time constants.
- Added `workflow` to `hive status --json` task rows and preserved that field
  through daemon, bot, and TUI row mirrors so row-based consumers can guard
  coding-specific plan/brainstorm/review/finalize behavior.
- Relaxed CLI stage-ref parsing for `run` / `approve` to validate against the
  resolved task workflow, taught status and `TaskResolver` to scan the live
  descriptor stage-dir union, and gated bespoke runner name precedence to
  `descriptor.id == :coding` so non-coding name collisions route by descriptor
  kind.
- Split generic first-run action wiring so markerless generic agent stages emit
  `ready_to_run` and daemon policy can dispatch `hive run <slug>`, while
  generic `WAITING` markers still go through the edit/mtime debounce path.
- Added `test/unit/stage_literal_guard_test.rb`; every surviving hardcoded live
  stage literal under `lib/` must now be migrated or carry a same-line
  `# coding-scoped:` / `# not-a-stage-ref:` annotation with a reason.

**Literal triage summary:**

| Area | Mode | Result | Reason |
|------|------|--------|--------|
| Bot notification/status watcher/supervisor surfaces | stage identity/path | Guarded coding-scope plus `workflow` row field | Brainstorm answer buttons and plan-pause notifications are coding-only; generic waiting rows now get neutral details. |
| Daemon policy/healer | stage identity/argv | Guarded coding-scope plus descriptor dispatch | Plan auto-approval, review exclusion, finalize unpushed-commit retry, and coding plan rerun are coding-specific; generic `ready_to_run` / `ready_to_advance` dispatch through descriptor commands. |
| Status, task resolver, and CLI stage-ref gates | path/validation | Migrated | They scan `Hive::Workflows.all_stage_dirs` and validate stage refs against the resolved workflow or live registry. |
| Stages resolver and generic agent runner | runner dispatch | Migrated | Non-coding stage-name collisions route by descriptor kind and `Stages::Agent` resolves stage metadata from `task.workflow`. |
| Title formatter, TUI affordances, doctor/new/bench/patrol/reviewer/digest/core coding constants | labels/path/fixtures | Annotated coding-scoped | These are coding UI, diagnostics, task creation, review/PR, archive, or dependency-gate concepts. |
| Migration/recovery legacy maps and comments | legacy/docs | Annotated not-a-stage-ref | Historical remaps and examples are not live descriptor references. |

**Verification:** Characterization tests were added before the refactor, the
literal guard is green, and the new
`test/integration/generic_workflow_daemon_e2e_test.rb` drives a registered
generic workflow through status -> daemon policy -> `hive run` -> `hive approve`
for two stage hops while a coding task in the same project keeps its coding
dispatch path.

**Pages:** [[modules/workflows]], [[modules/task_action]], [[modules/daemon]],
[[commands/status]], [[gaps]]
