---
title: Hive::TaskAction
type: module
source: lib/hive/task_action.rb
created: 2026-04-26
updated: 2026-06-20
tags: [module, status, action, classifier, diagnostic]
---

**TLDR**: Classifier that turns a `(Hive::Task, Hive::Markers::State)` pair into a user-facing action with a stable key (per `Hive::Schemas::TaskActionKind`), a human label for `hive status` output, a copy-paste-executable shell command, an optional structured `next_action` for row-specific recovery, and (since 2026-05-16) a bounded `diagnostic` payload for red recovery rows. Used by `hive status` (action grouping + `tasks[].action`/`diagnostic` JSON fields), `hive run` (`next_action.command` / `rerun_with`), `hive approve` (`next_action.command` after a successful advance), `hive accept-finding` / `hive reject-finding` (`next_action.command` after a toggle), and `hive status --diagnose` (`#diagnostic` is the local fallback path when no agent-written artifact is fresh).

## Public surface

```ruby
action = Hive::TaskAction.for(task, marker, project_name: nil, project_count: 1, stage_collision: false, live_task_lock: false)
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

`suggested_next_action` is populated for `:review_error` / `:review_ci_stale` / wall-clock `:review_stale` / `:error` markers via `retry_command_string` (`hive markers clear ... && hive run ...` as a shell one-liner). `:error` retry commands prefer `--match-attr marker_id=<current>` and fall back to observed `reason`/`exit_code` pairs for legacy markers; marker summaries and details hide internal `marker_id` values. For `:execute_stale`, legacy `:execute_waiting findings_count>0`, and max-passes `:review_stale`, the value reports `kind: manual_fix` with `command: nil` — the operator must edit or inspect findings before retry.

EXECUTE_STALE rows and legacy `EXECUTE_WAITING findings_count>0` rows emit a non-nil `diagnostic` even though `Hive::Tui::KeyMap#red_detail_row?` does not yet open the detail view for them; bot/daemon/external-agent consumers of `hive status --json` rely on the field to explain why an EXECUTE_STALE task is stuck.

## Action map (`Hive::TaskAction::ACTIONS`)

Entries are keyed by an internal symbol that's resolved via `(stage_name, marker_name)` lookup. Each value carries `key` (TaskActionKind constant), `label` (human prose), and `command` (verb name string, or nil).

| Internal key | TaskActionKind | Label | Verb |
|---|---|---|---|
| `inbox` | `READY_TO_BRAINSTORM` | "Ready to brainstorm" | brainstorm |
| `brainstorm_waiting` | `NEEDS_INPUT` | "Needs your input" | brainstorm |
| `brainstorm_complete` | `READY_TO_PLAN` | "Ready to plan" | plan |
| `plan_waiting` | `NEEDS_INPUT` | "Needs your input" | plan |
| `plan_complete` | `READY_TO_DEVELOP` | "Ready to develop" | develop |
| `execute_waiting` | `NEEDS_INPUT` | "Needs your input" | develop |
| `execute_complete` | `READY_TO_OPEN_PR` | "Ready to open PR" | open-pr |
| `open_pr_complete` | `READY_FOR_REVIEW` | "Ready for review" | review |
| `execute_stale` | `RECOVER_EXECUTE` | "Needs recovery" | findings |
| `review_ready` | `READY_FOR_REVIEW` | "Ready for review" | review |
| `review_waiting` | `NEEDS_INPUT` | "Needs your input" | review |
| `review_complete` | `READY_TO_ARTIFACTS` | "Ready to collect artifacts" | artifacts |
| `artifacts_ready` | `READY_TO_ARTIFACTS` | "Ready to collect artifacts" | artifacts |
| `artifacts_complete` | `READY_TO_FINALIZE` | "Ready to finalize" | finalize |
| `review_stale` | `RECOVER_REVIEW` | "Needs recovery" | nil |
| `finalize_waiting` | `NEEDS_INPUT` | "Needs your input" | finalize |
| `finalize_complete` | `READY_TO_ARCHIVE` | "Ready to archive" | archive |
| `ready_to_advance` | `READY_TO_ADVANCE` | "Ready to advance" | approve |
| `generic_ready_to_run` | `NEEDS_INPUT` | "Ready to run" | run |
| `generic_needs_input` | `NEEDS_INPUT` | "Needs your input" | run |
| `agent_running` | `AGENT_RUNNING` | "Agent running" | nil |
| `done` | `ARCHIVED` | "Archived" | nil |
| `error` | `ERROR` | "Error" | nil |

## Workflow-aware branch

`TaskAction#action` keeps the coding workflow on the existing hand-tuned
stage-name `case` after the workflow-agnostic short-circuits (`live_task_lock`,
`AGENT_WORKING`, `ERROR`, and `MANUAL_STEERING`). Tasks whose resolved
`task.workflow.id` is not `:coding` use a descriptor-positioned generic
classifier instead:

- `COMPLETE` at the terminal descriptor stage -> `archived`.
- `COMPLETE` at any earlier descriptor stage -> `ready_to_advance`.
- `WAITING` -> `needs_input`.
- markerless entry stage -> `ready_to_advance`.
- markerless non-entry stage -> `needs_input` with label "Ready to run".

This keeps coding behavior byte-stable while letting registered non-coding
workflows surface non-error status rows once a task has resolved to its
descriptor. The physical folder move for generic stages still depends on the
later descriptor-aware `approve`/verb work; this branch proves classification
and daemon decision shape.

## Marker carve-outs

Runtime liveness can short-circuit per-stage dispatch before marker lookup:

- **`live_task_lock: true`** → `agent_running` (label "Agent running", command nil). `Hive::Commands::Status` sets this when a task `.lock` holder PID is alive and its recorded process start time still matches. This covers pre-marker work inside `hive run`, such as auto-rebase before `REVIEW_WORKING` is written, so status and the TUI do not offer a duplicate runnable command that would immediately hit `ConcurrentRunError`.
- **`:agent_working`** → `agent_running` (label "Agent running", command nil) when the agent is actually alive. A `hive run` is in flight; surfacing a workflow command would send the user (or an agent retry loop) straight into `ConcurrentRunError`. **Stale carve-out:** when the caller passes `pid_alive:` and `state_file_mtime:` kwargs and either (a) `pid_alive` is `false` (the per-task `.lock` recorded a `claude_pid` that's now dead), or (b) `pid_alive` is `nil` (no `.lock` claude_pid), the marker has no `pid` attr, and the state-file mtime is older than `agent_marker_grace_sec` (default 300s; threaded from `daemon.agent_marker_grace_sec` by `Hive::Commands::Status`), the action is reclassified as `:error` with a synthesized diagnostic (summary describes "agent process not alive" / "agent never attached"; detail explains the daemon will heal the on-disk marker within ~30s). This makes the row a recoverable red status immediately, without waiting for the daemon's `StaleAgentHealer` to rewrite the marker on disk.
- **`:error`** → always `error` at the status/action layer. The stage agent recorded a failure; recovery is manual unless diagnostics expose a guarded retry command or the daemon healer owns one of its narrow auto-clear paths. The healer-written subset (`reason=agent_died` / `reason=agent_orphaned`) must be re-read through `hive status --json` / red-status detail after the daemon rewrites the marker so consumers use the current `suggested_next_action.command` with the `marker_id` guard. Separately, `StaleAgentHealer` may auto-clear no-live-lock terminal `ERROR reason=tmux_session_terminated` / `reason=agent_orphaned` in non-review stages; `3-plan` additionally queues a same-stage `hive plan ... --from 3-plan` rerun because an empty markerless `plan.md` remains `:error` here and is skipped by daemon policy.

`:execute_stale` maps to `RECOVER_EXECUTE` and emits `hive findings <slug>` rather than a workflow verb. Legacy `:execute_waiting findings_count>0` uses the same recovery surface so old state folders do not fall through to generic edit guidance. Running `hive develop <slug>` on either shape would refuse or loop on a non-terminal marker; pointing the user at `findings` opens the recovery loop instead.

Markerless `6-review` tasks map to `READY_FOR_REVIEW`, not `NEEDS_INPUT`. This matters after a recovery marker is cleared: the next useful action is to run the review stage, while only an explicit `REVIEW_WAITING` marker should open the input-editor path.

## Command emission

Workflow verbs (`brainstorm`/`plan`/`develop`/`open-pr`/`review`/`artifacts`/`finalize`/`archive`) ALWAYS include `--from <stage>`. That's the idempotency lever: a retry after a successful advance fails with `WRONG_STAGE` (4) instead of silently advancing twice.

Generic verbs (`findings`/`accept-finding`/`reject-finding`) include `--stage <stage>` only when slug-stage ambiguity actually exists (`stage_collision: true`).

For non-coding workflows, command emission bypasses the coding
`Hive::Workflows::VERBS` table. `ready_to_advance` emits
`hive approve <slug> --from <descriptor-stage-dir>` and generic run/input rows
emit `hive run <slug>` (plus `--project` when the status snapshot spans multiple
projects, and `--stage` for run rows only when a stage collision was reported).

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
