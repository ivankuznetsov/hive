---
title: Hive::TaskAction
type: module
source: lib/hive/task_action.rb
created: 2026-04-26
updated: 2026-04-26
tags: [module, status, action, classifier]
---

**TLDR**: Classifier that turns a `(Hive::Task, Hive::Markers::State)` pair into a user-facing action with a stable key (per `Hive::Schemas::TaskActionKind`), a human label for `hive status` output, and a copy-paste-executable shell command for the next step. Used by `hive status` (action grouping + `tasks[].action` JSON field), `hive run` (`next_action.command` / `rerun_with`), `hive approve` (`next_action.command` after a successful advance), and `hive accept-finding` / `hive reject-finding` (`next_action.command` after a toggle).

## Public surface

```ruby
action = Hive::TaskAction.for(task, marker, project_name: nil, project_count: 1, stage_collision: false)
action.key         # closed enum string per Hive::Schemas::TaskActionKind
action.label       # human label, e.g. "Ready to plan"
action.command     # copy-paste shell command, or nil
action.payload     # { "key", "label", "command" } for JSON emission
```

## Action map (`Hive::TaskAction::ACTIONS`)

13 entries, keyed by an internal symbol that's resolved via `(stage_name, marker_name)` lookup. Each value carries `key` (TaskActionKind constant), `label` (human prose), and `command` (verb name string, or nil).

| Internal key | TaskActionKind | Label | Verb |
|---|---|---|---|
| `inbox` | `READY_TO_BRAINSTORM` | "Ready to brainstorm" | brainstorm |
| `brainstorm_waiting` | `NEEDS_INPUT` | "Needs your input" | brainstorm |
| `brainstorm_complete` | `READY_TO_PLAN` | "Ready to plan" | plan |
| `plan_waiting` | `NEEDS_INPUT` | "Needs your input" | plan |
| `plan_complete` | `READY_TO_DEVELOP` | "Ready to develop" | develop |
| `execute_findings` | `REVIEW_FINDINGS` | "Review findings" | findings |
| `execute_waiting` | `NEEDS_INPUT` | "Needs your input" | develop |
| `execute_complete` | `READY_FOR_PR` | "Ready for PR" | pr |
| `execute_stale` | `RECOVER_EXECUTE` | "Needs recovery" | findings |
| `pr_waiting` | `NEEDS_INPUT` | "Needs your input" | pr |
| `pr_complete` | `READY_TO_ARCHIVE` | "Ready to archive" | archive |
| `agent_running` | `AGENT_RUNNING` | "Agent running" | nil |
| `done` | `ARCHIVED` | "Archived" | nil |
| `error` | `ERROR` | "Error" | nil |

## Marker carve-outs

Two markers short-circuit the per-stage dispatch:

- **`:agent_working`** → always `agent_running` (label "Agent running", command nil). A `hive run` is in flight; surfacing a workflow command would send the user (or an agent retry loop) straight into `ConcurrentRunError`.
- **`:error`** → always `error`. The stage agent recorded a failure; recovery is manual (edit reviews/, lower frontmatter pass:, remove EXECUTE_STALE marker, etc.).

`:execute_stale` maps to `RECOVER_EXECUTE` and emits `hive findings <slug> --pass <N>` rather than a workflow verb. Running `hive develop <slug>` on a stale task would refuse on the non-terminal marker; pointing the user at `findings` opens the recovery loop instead of a verb-rejection loop.

## Command emission

Workflow verbs (`brainstorm`/`plan`/`develop`/`pr`/`archive`) ALWAYS include `--from <stage>`. That's the idempotency lever: a retry after a successful advance fails with `WRONG_STAGE` (4) instead of silently advancing twice.

Generic verbs (`findings`/`accept-finding`/`reject-finding`) include `--stage <stage>` only when slug-stage ambiguity actually exists (`stage_collision: true`).

`--project <name>` is appended whenever `project_count > 1` so multi-project status output emits unambiguous commands.

The slug is `Shellwords.shelljoin`-escaped so a slug containing shell metacharacters can't break the suggested command.

## Consumers

| File | Use |
|------|-----|
| `lib/hive/commands/status.rb` | `annotate_actions` calls `TaskAction.for` per row and routes by `action_key` for grouping. JSON `tasks[].action`/`action_label`/`suggested_command` come from this. |
| `lib/hive/commands/run.rb` | `friendly_command` and `approve_action` delegate; `next_action.command` and `rerun_with` use the workflow form. |
| `lib/hive/commands/approve.rb` | `json_next_action` builds the post-advance command via `TaskAction.for(post_move_task)` so the user lands on a runnable form for the new stage. |
| `lib/hive/commands/stage_action.rb` | `success_payload` includes a `next_action` block built from TaskAction. |

## Why a class, not a hash lookup?

Most of the data IS in the `ACTIONS` hash, but `command` needs to compose multiple inputs (`project_name`, `project_count`, `stage_collision`, the verb's `from`-vs-`stage` flag preference). Wrapping in a class keeps the call site one method (`.for(task, marker, **)`) and centralises the flag-emission logic.

## Backlinks

- [[commands/status]] · [[commands/run]] · [[commands/approve]] · [[commands/findings]]
- [[modules/workflows]] — verb→stage map this module consults
- [[modules/markers]] — the marker name space this module switches on
