---
title: Hive::ExecuteWaitingAction
type: module
source: lib/hive/execute_waiting_action.rb
created: 2026-05-13
updated: 2026-09-14
tags: [module, execute, status, json, tui]
---

**TLDR**: Shared builder for `EXECUTE_WAITING reason=...` recovery actions. It returns a `next_action` hash with `kind`, `target`, `instructions`, and optional `rerun_with` so `hive run --json`, the internal task projection, and the TUI all point at the same repair target.

## Reasons

| Reason | Kind | Target |
|---|---|---|
| `dirty_worktree` | `edit` | the execute worktree path from `worktree.yml` |
| `branch_mismatch` / `head_not_descendant` | `edit` | the execute worktree path from `worktree.yml` |
| `no_worktree_changes` | `edit` | `<task>/plan.md` |
| `missing_research_output` | `run` | the task folder |
| `attempt_lost` / `attempt_terminal_failed` / `attempt_terminal_cancelled` | `run` | the task folder |
| `worktree_evidence_unverifiable` / `evidence_unverifiable` / `attempt_state_unverifiable` | `edit` | the execute worktree path |
| unknown | `edit` | the task state file |

`missing_research_output` is intentionally `kind=run`: editing `task.md` by hand cannot satisfy the execute runner's structured final-message gate. The operator or agent must rerun with an agent/profile/prompt that emits a final answer Hive can capture under `## Execute Output`.

## Pause classification

`technical_reason?` identifies the known repair reasons above. `TaskAction` uses
that classification for both legacy waiting markers and authoritative condition
gate diagnostics: these produce `recover_execute` / **Needs execution repair**,
with the same structured repair guidance and explicit rerun command. The daemon
does not automatically resume this action; operational status reports
`needs_repair`, owned by the operator. Missing or unknown reasons retain the
legacy **Needs your input** classification.

No-change output is insufficient evidence of a human question. Worktree evidence
errors concern Git or attempt-store integrity, not unavailable screenshots.
Condition inhibitor observations remain unchanged: reclassifying their display
must not accidentally waive branch, baseline, or dirty-worktree blockers.

## Consumers

| File | Use |
|---|---|
| `lib/hive/commands/run.rb` | Builds `hive run --json next_action` for `:execute_waiting`. |
| `lib/hive/task_action.rb` | Adds row-local `next_action` to internal task projections through `TaskAction#next_action`. |
| `lib/hive/tui/key_map.rb` / `lib/hive/tui/bubble_model.rb` | Enter on execute waiting rows opens edit targets or dispatches run actions from the same structured payload. |
