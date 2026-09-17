## High

- [x] AUTO-FIX: Human-stage entry follows task-controlled symlinks (`lib/hive/commands/approve.rb:300`): a prior `yolo` agent can make `approval.md` point outside the task, causing Hive to copy and commit external bytes when the stage is entered. <!-- triage: plan safety invariant makes no-follow file handling required -->
- [x] AUTO-FIX: Decision retries are not bound to an approval visit (`lib/hive/commands/decide.rb:39`): because callers provide no observed `decision_id`, a delayed decision from an earlier visit can apply to a later visit after reject, redraft, and re-entry. <!-- triage: U2 explicitly requires persisted decision identity to reject stale decisions -->
- [x] AUTO-FIX: Minimal init can replace another project registration (`lib/hive/commands/init.rb:723`): a fresh target sharing an existing project's basename silently redirects that global registry entry despite the preview never disclosing the overwrite. <!-- triage: R4 and AE4 forbid overwriting unrelated project choices -->
- [x] AUTO-FIX: Workflow validation can mutate managed state (`lib/hive/commands/workflow/validate.rb:32`): production resolution creates the mutation lock and may restore a managed pointer and clear its transaction journal, violating the command's strict read-only contract. <!-- triage: U3 explicitly requires strictly read-only validation -->
- [x] AUTO-FIX: The creator leaves the authored workflow graph uncommitted (`skills/hive/references/workflow-creator.md:58`): `workflow new` commits the blank scaffold, while later edits are only validated, so a Hive-state reset restores the wrong graph and can strand tasks. <!-- triage: R1 and R7 require the populated loadable graph to be the durable created result -->
- [x] AUTO-FIX: Marker-only drafts are accepted as publish-ready (`lib/hive/commands/decide.rb:157`): the raw positive-size check treats a file containing only Hive marker comments as a non-empty publishable artifact. <!-- triage: U2 requires a genuinely non-empty publish-ready artifact -->

## Medium

- [x] AUTO-FIX: New command usage errors use the wrong JSON contract (`bin/hive:364`): malformed `decide --json` calls return prose and malformed `workflow validate --json` calls are mislabeled as `hive-workflow-new`. <!-- triage: U2 and U3 require stable command-specific JSON envelopes -->
- [x] AUTO-FIX: Minimal-init JSON failures return prose (`bin/hive:545`): dirty, already-initialized, invalid, and collision failures bypass typed JSON, so the canonical creator cannot branch on its machine-readable failure contract. <!-- triage: U4 requires machine-readable preview and failure handling -->
- [x] AUTO-FIX: Completed human stages still request a decision (`lib/hive/commands/run.rb:80`): `hive run --json` reports `human_decision_required` and allowed outcomes for a `COMPLETE` human stage even though status classifies it as done. <!-- triage: U2 requires completed outcomes to complete the workflow -->
- [x] AUTO-FIX: Same-slug idempotent creates bypass conflict detection (`lib/hive/commands/new.rb:233`): concurrent contenders can share the final task directory, which the locked recheck excludes, so both may report `created: true` or different inputs may overwrite one another. <!-- triage: R9 and AE5 require at-most-once task creation across retries -->

## Nit
