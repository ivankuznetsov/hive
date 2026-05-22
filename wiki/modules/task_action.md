---
title: Hive::TaskAction
type: module
source: lib/hive/task_action.rb
created: 2026-04-26
updated: 2026-05-19
tags: [module, status, action, classifier, diagnostic]
---

**TLDR**: Classifier that turns a `(Hive::Task, Hive::Markers::State)` pair into a user-facing action with a stable key (per `Hive::Schemas::TaskActionKind`), a human label for `hive status` output, a copy-paste-executable shell command, an optional structured `next_action` for row-specific recovery, and (since 2026-05-16) a bounded `diagnostic` payload for red recovery rows. Used by `hive status` (action grouping + `tasks[].action`/`diagnostic` JSON fields), `hive run` (`next_action.command` / `rerun_with`), `hive approve` (`next_action.command` after a successful advance), `hive accept-finding` / `hive reject-finding` (`next_action.command` after a toggle), and `hive status --diagnose` (`#diagnostic` is the local fallback path when no agent-written artifact is fresh).

## Public surface

```ruby
action = Hive::TaskAction.for(task, marker, project_name: nil, project_count: 1, stage_collision: false)
action.key         # closed enum string per Hive::Schemas::TaskActionKind
action.label       # human label, e.g. "Ready to plan"
action.command     # copy-paste shell command, or nil
action.next_action # structured row-local recovery action, or nil
action.diagnostic  # bounded diagnostic payload for recover_review / recover_execute / error rows, nil otherwise
action.payload     # { "key", "label", "command", "next_action" } for JSON emission
```

## Red-status diagnostic (`#diagnostic`)

`#diagnostic` returns a Hash matching the `Diagnostic` shape under both `hive-status.v2` (`tasks[].diagnostic`) and `hive-status-diagnose.v1` (`SuccessPayload.diagnostic`). It is non-nil for exactly three action keys: `recover_review`, `recover_execute`, and `error` (see `#diagnostic_action?`). Every other row returns `nil`.

The payload is the local-extraction fallback. When a fresh agent-written `<task.folder>/diagnostics/red-status.md` exists (frontmatter `marker_signature` matches the current marker's SHA256 and `generated_by` is in `Hive::Schemas::DIAGNOSTIC_GENERATORS`), `diagnostic_generated_by` returns the producing generator name (`claude`/`codex`/`pi`) and the artifact body becomes the source of truth. Otherwise it bounds the output via `DIAGNOSTIC_SUMMARY_MAX` (120 chars), `DIAGNOSTIC_DETAIL_MAX` (4000 chars), and `ARTIFACT_PATHS_MAX` (20 paths). All summary/detail text passes through `redact` (using `Hive::SecretPatterns`) before emission.

Diagnostic artifacts are resolved with `File.realpath` and accepted only when they remain inside the project-controlled task/log roots, so a symlink under `reviews/`, `logs/`, or `diagnostics/` cannot make `hive status --json` tail arbitrary host files.

`marker_signature` is the SHA256 hex of `marker.name + sorted(attrs)` joined by newline. It's the freshness key shared with `Hive::DiagnosisAgent` (which validates it pre-write) and the TUI live-update gate (`Hive::Tui::Update#red_status_marker_signature`); producer + both consumers compute identical bytes.

`suggested_next_action` is populated for `:review_error` / `:review_ci_stale` / wall-clock `:review_stale` / `:error` markers via `retry_command_string` (`hive markers clear ... && hive run ...` as a shell one-liner). For `:execute_stale` and max-passes `:review_stale`, the value is `nil` — the operator must edit before retry.

EXECUTE_STALE rows emit a non-nil `diagnostic` even though `Hive::Tui::KeyMap#red_detail_row?` does not yet open the detail view for them; bot/daemon/external-agent consumers of `hive status --json` rely on the field to explain why an EXECUTE_STALE task is stuck.

## Action map (`Hive::TaskAction::ACTIONS`)

Entries are keyed by an internal symbol that's resolved via `(stage_name, marker_name)` lookup. Each value carries `key` (TaskActionKind constant), `label` (human prose), and `command` (verb name string, or nil).

| Internal key | TaskActionKind | Label | Verb |
|---|---|---|---|
| `inbox` | `READY_TO_BRAINSTORM` | "Ready to brainstorm" | brainstorm |
| `brainstorm_waiting` | `NEEDS_INPUT` | "Needs your input" | brainstorm |
| `brainstorm_complete` | `READY_TO_PLAN` | "Ready to plan" | plan |
| `plan_waiting` | `NEEDS_INPUT` | "Needs your input" | plan |
| `plan_complete` | `READY_TO_DEVELOP` | "Ready to develop" | develop |
| `execute_findings` | `REVIEW_FINDINGS` | "Review findings" | findings |
| `execute_waiting` | `NEEDS_INPUT` | "Needs your input" | develop |
| `execute_complete` | `READY_TO_OPEN_PR` | "Ready to open PR" | open-pr |
| `open_pr_complete` | `READY_FOR_REVIEW` | "Ready for review" | review |
| `execute_stale` | `RECOVER_EXECUTE` | "Needs recovery" | findings |
| `review_ready` | `READY_FOR_REVIEW` | "Ready for review" | review |
| `review_waiting` | `NEEDS_INPUT` | "Needs your input" | review |
| `review_complete` | `READY_TO_FINALIZE` | "Ready to finalize" | finalize |
| `review_stale` | `RECOVER_REVIEW` | "Needs recovery" | nil |
| `finalize_waiting` | `NEEDS_INPUT` | "Needs your input" | finalize |
| `finalize_complete` | `READY_TO_ARCHIVE` | "Ready to archive" | archive |
| `agent_running` | `AGENT_RUNNING` | "Agent running" | nil |
| `done` | `ARCHIVED` | "Archived" | nil |
| `error` | `ERROR` | "Error" | nil |

## Marker carve-outs

Two markers short-circuit the per-stage dispatch:

- **`:agent_working`** → `agent_running` (label "Agent running", command nil) when the agent is actually alive. A `hive run` is in flight; surfacing a workflow command would send the user (or an agent retry loop) straight into `ConcurrentRunError`. **Stale carve-out:** when the caller passes `pid_alive:` and `state_file_mtime:` kwargs and either (a) `pid_alive` is `false` (the per-task `.lock` recorded a `claude_pid` that's now dead), or (b) `pid_alive` is `nil` (no `.lock` claude_pid), the marker has no `pid` attr, and the state-file mtime is older than `agent_marker_grace_sec` (default 300s; threaded from `daemon.agent_marker_grace_sec` by `Hive::Commands::Status`), the action is reclassified as `:error` with a synthesized diagnostic (summary describes "agent process not alive" / "agent never attached"; detail explains the daemon will heal the on-disk marker within ~30s). This makes the row a recoverable red status immediately, without waiting for the daemon's `StaleAgentHealer` to rewrite the marker on disk.
- **`:error`** → always `error`. The stage agent recorded a failure; recovery is manual (edit reviews/, lower frontmatter pass:, remove EXECUTE_STALE marker, etc.). The healer-written subset (`reason=agent_died` / `reason=agent_orphaned`) recovers via the standard `hive markers clear <slug> --name ERROR` flow once the on-disk rewrite lands.

`:execute_stale` maps to `RECOVER_EXECUTE` and emits `hive findings <slug> --pass <N>` rather than a workflow verb. Running `hive develop <slug>` on a stale task would refuse on the non-terminal marker; pointing the user at `findings` opens the recovery loop instead of a verb-rejection loop.

Markerless `6-review` tasks map to `READY_FOR_REVIEW`, not `NEEDS_INPUT`. This matters after a recovery marker is cleared: the next useful action is to run the review stage, while only an explicit `REVIEW_WAITING` marker should open the input-editor path.

## Command emission

Workflow verbs (`brainstorm`/`plan`/`develop`/`open-pr`/`review`/`finalize`/`archive`) ALWAYS include `--from <stage>`. That's the idempotency lever: a retry after a successful advance fails with `WRONG_STAGE` (4) instead of silently advancing twice.

Generic verbs (`findings`/`accept-finding`/`reject-finding`) include `--stage <stage>` only when slug-stage ambiguity actually exists (`stage_collision: true`).

`--project <name>` is appended whenever `project_count > 1` so multi-project status output emits unambiguous commands.

The slug is `Shellwords.shelljoin`-escaped so a slug containing shell metacharacters can't break the suggested command.

`EXECUTE_WAITING` rows with no pending findings delegate their structured `next_action` to `Hive::ExecuteWaitingAction`. That keeps `hive status --json`, `hive run --json`, and TUI Enter behavior aligned for `dirty_worktree`, `branch_mismatch`, `head_not_descendant`, `no_worktree_changes`, and `missing_research_output`.

## Consumers

| File | Use |
|------|-----|
| `lib/hive/commands/status.rb` | `annotate_actions` calls `TaskAction.for` per row and routes by `action_key` for grouping. JSON `tasks[].action`/`action_label`/`suggested_command`/`next_action` come from this. |
| `lib/hive/commands/run.rb` | `friendly_command` and `approve_action` delegate; `next_action.command` and `rerun_with` use the workflow form. |
| `lib/hive/commands/approve.rb` | `json_next_action` builds the post-advance command via `TaskAction.for(post_move_task)` so the user lands on a runnable form for the new stage. |
| `lib/hive/commands/stage_action.rb` | `success_payload` includes a `next_action` block built from TaskAction. |

## Why a class, not a hash lookup?

Most of the data IS in the `ACTIONS` hash, but `command` needs to compose multiple inputs (`project_name`, `project_count`, `stage_collision`, the verb's `from`-vs-`stage` flag preference). Wrapping in a class keeps the call site one method (`.for(task, marker, **)`) and centralises the flag-emission logic.

## Backlinks

- [[commands/status]] · [[commands/run]] · [[commands/approve]] · [[commands/findings]]
- [[modules/workflows]] — verb→stage map this module consults
- [[modules/markers]] — the marker name space this module switches on
- [[modules/diagnosis_agent]] — headless agent that writes the artifact this module prefers when fresh
- [[modules/secret_patterns]] — redaction patterns used by `#diagnostic`'s summary/detail emission
- [[decisions]] ADR-025 (required-and-nullable JSON envelopes) and ADR-027 (red-status diagnose-then-act)
