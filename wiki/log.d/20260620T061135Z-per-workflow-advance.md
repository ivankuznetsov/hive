## [2026-06-20T06:11:35Z] workflows - descriptor-aware generic advance routing

**Action:** U5 moved generic advance resolution into descriptor-aware command
paths: `Hive::Commands::Approve` now resolves `--to`, `--from`, forward
destinations, validation, payload stage fields, and text next-hints through
`task.workflow`; `Hive::Commands::Run#next_stage_dir` now emits approve actions
for the task workflow's actual next stage. Coding verb constants remain derived
from the default descriptor for legacy consumers.

**Docs:** Updated [[modules/task_action]] to distinguish post-U5 generic
advance routing from the still-deferred first-run generic auto-dispatch gap, and
retargeted the generic stale/error resting-marker gap as future descriptor
workflow work rather than U5 scope.
