---
title: Hive::TaskAction
type: module
source: lib/hive/task_action.rb
created: 2026-04-26
updated: 2026-07-25
tags: [module, status, action, classifier, human-stage, diagnostic]
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

`#diagnostic` returns a Hash matching the `Diagnostic` shape under both the current `hive-status` contract (`tasks[].diagnostic`) and `hive-status-diagnose.v2` (`SuccessPayload.diagnostic`). It is non-nil for exactly three action keys: `recover_review`, `recover_execute`, and `error` (see `#diagnostic_action?`). Every other row returns `nil`.

The payload is the local-extraction fallback. When a fresh agent-written `<task.folder>/diagnostics/red-status.md` exists (frontmatter `marker_signature` matches the current marker's SHA256 and `generated_by` is in `Hive::Schemas::DIAGNOSTIC_GENERATORS`), `diagnostic_generated_by` returns the producing generator name (`claude`/`codex`/`pi`/`grok`) and the artifact body becomes the source of truth. Otherwise it bounds the output via `DIAGNOSTIC_SUMMARY_MAX` (120 chars), `DIAGNOSTIC_DETAIL_MAX` (4000 chars), and `ARTIFACT_PATHS_MAX` (20 paths). All summary/detail text passes through `redact` (using `Hive::SecretPatterns`) before emission.

Diagnostic artifacts are resolved with `File.realpath` and accepted only when they remain inside the project-controlled task/log roots, so a symlink under `reviews/`, `logs/`, or `diagnostics/` cannot make `hive status --json` tail arbitrary host files.

`marker_signature` is the SHA256 hex of `marker.name + sorted(attrs)` joined by newline. It's the freshness key shared with `Hive::DiagnosisAgent` (which validates it pre-write) and the TUI live-update gate (`Hive::Tui::Update#red_status_marker_signature`); producer + both consumers compute identical bytes.

`suggested_next_action` is populated for `:review_error` / `:review_ci_stale` / wall-clock `:review_stale` / `:error` markers with the guarded agent action `hive act workflow.retry PROJECT:SLUG --observation TOKEN`. The token binds the complete current observation, including marker occurrence; direct `markers clear && run` recipes are intentionally not published because they bypass the durable lifecycle. For `:execute_stale`, legacy `:execute_waiting findings_count>0`, and max-passes `:review_stale`, the value reports `kind: manual_fix` with `command: nil` — the operator must edit or inspect findings before retry.

EXECUTE_STALE rows and legacy `EXECUTE_WAITING findings_count>0` rows emit a non-nil `diagnostic` even though `Hive::Tui::KeyMap#red_detail_row?` does not yet open the detail view for them; bot/daemon/external-agent consumers of `hive status --json` rely on the field to explain why an EXECUTE_STALE task is stuck.

## Action map (`Hive::TaskAction::ACTIONS`)

Entries are keyed by an internal symbol resolved by routing on the descriptor stage's `kind` (see the "Kind-Routed Classification" section below): coding `:agent`/`:inert` stages map through `Hive::Workflows::Coding::ACTION_DISPATCH`, the coding runtime kinds (`:execute`/`:review_council`/`:finalize`) select their helpers directly, and non-coding stages fall through to the descriptor-generic classifier — the older `(stage_name, marker_name)` case lookup is retired. Each value carries `key` (TaskActionKind constant), `label` (human prose), and `command` (verb name string, or nil).

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
| `generic_ready_to_run` | `READY_TO_RUN` | "Ready to run" | run |
| `generic_needs_input` | `NEEDS_INPUT` | "Needs your input" | run |
| `agent_running` | `AGENT_RUNNING` | "Agent running" | nil |
| `done` | `ARCHIVED` | "Archived" | nil |
| `error` | `ERROR` | "Error" | nil |

`generic_ready_to_run` and `generic_needs_input` are distinct on the JSON wire.
Markerless generic stages emit `READY_TO_RUN` so the daemon can dispatch
`hive run <slug>` on first sight. Generic `WAITING` markers still emit
`NEEDS_INPUT` and go through the edit/mtime debounce path. Coding also uses
`generic_ready_to_run` for markerless brainstorm and execute rows, and for
markerless finalize rows once `pr.md` exists; those are runnable states, not
operator-input gates. This split is additive to `Hive::Schemas::TaskActionKind`
and is mirrored by `hive-status` and `hive-stage-action` schemas.

## Kind-Routed Classification

`TaskAction#action` first applies the workflow-agnostic short-circuits
(`live_task_lock`, `AGENT_WORKING`, `ERROR`, and `MANUAL_STEERING`), then routes
through the resolved descriptor stage's `kind`. Coding no longer has a
production `case task.stage_name` branch: `:execute`, `:review_council`, and
`:finalize` select the coding runtime-specific helpers directly, while coding
`:agent`/`:inert` stages consult `Hive::Workflows::Coding::ACTION_DISPATCH` for
their per-stage user-facing action keys. Non-coding `:agent`/`:inert`/nil
stages fall through to the descriptor-generic classifier:

- `COMPLETE` at the terminal descriptor stage -> `archived`.
- `COMPLETE` at any earlier descriptor stage -> `ready_to_advance`.
- `WAITING` -> `generic_needs_input` (wire kind `NEEDS_INPUT`).
- markerless any non-terminal inert stage -> `ready_to_advance`. The gate is
  `!terminal && stage.kind == :inert` with no entry-stage condition: the
  entry-only restriction was intentionally dropped so an inert MIDDLE stage
  advances rather than stranding (`Resolver.resolve` raises `StageError` for
  `kind: :inert`, so it can neither run nor advance otherwise).
- markerless stage of any non-inert kind (`:agent`, coding runtime kinds, or
  `nil`), or a
  terminal inert stage (degenerate single-stage workflow, entry == terminal) ->
  `generic_ready_to_run` with label "Ready to run".

Coding behavior is pinned by the same matrix while the classifier routes through
descriptor `kind:`. A test-only parity harness compares the retired stage-name
case against the production kind path across coding markers, diagnostics, and
command strings. `Commands::Approve` and `Commands::Run` resolve generic advance
destinations through the task's descriptor, the CLI accepts runtime-registered
stage refs for `--from`/`--to`/`--stage`, `Status#collect_rows` scans
`Hive::Workflows.all_stage_dirs`, and `TaskResolver` can find generic-only stage
dirs by bare slug. U6's integration test proves a registered generic task
advancing through status -> policy -> `hive run`/`hive approve` for two stage
hops.

## Marker carve-outs

Runtime liveness can short-circuit per-stage dispatch before marker lookup:

- **`live_task_lock: true`** → `agent_running` (label "Agent running", command nil). `Hive::Commands::Status` sets this when a task `.lock` holder PID is alive and its recorded process start time still matches. This covers pre-marker work inside `hive run`, such as auto-rebase before `REVIEW_WORKING` is written, so status and the TUI do not offer a duplicate runnable command that would immediately hit `ConcurrentRunError`.
- **`:agent_working`** → `agent_running` (label "Agent running", command nil) when the agent is actually alive. A `hive run` is in flight; surfacing a workflow command would send the user (or an agent retry loop) straight into `ConcurrentRunError`. **Stale carve-out:** when the caller passes `pid_alive:` and `state_file_mtime:` kwargs and either (a) `pid_alive` is `false` (the per-task `.lock` recorded a `claude_pid` that's now dead), or (b) `pid_alive` is `nil` (no `.lock` claude_pid), the marker has no `pid` attr, and the state-file mtime is older than `agent_marker_grace_sec` (default 300s; threaded from `daemon.agent_marker_grace_sec` by `Hive::Commands::Status`), the action is reclassified as `:error` with a synthesized diagnostic (summary describes "agent process not alive" / "agent never attached"; detail explains the daemon will heal the on-disk marker within ~30s). This makes the row a recoverable red status immediately, without waiting for the daemon's `StaleAgentHealer` to rewrite the marker on disk.
- **`:error`** → always `error` at the status/action layer. The stage agent recorded a failure; automatic and operator-triggered recovery both submit a fresh observation to `RecoveryCoordinator`. Consumers must refresh status before invoking the guarded `workflow.retry` action; no surface should construct its own marker-clear recipe. `StaleAgentHealer` uses the same coordinator for cooled terminal errors, including `tmux_session_terminated` / `agent_orphaned`. The coordinator derives the owning workflow command for every stage; `3-plan` therefore needs no separate clear/requeue mechanism even when an empty markerless `plan.md` would otherwise remain `:error`.

`:execute_stale` maps to `RECOVER_EXECUTE` and emits `hive findings <slug>` rather than a workflow verb. Legacy `:execute_waiting findings_count>0` uses the same recovery surface so old state folders do not fall through to generic edit guidance. Running `hive develop <slug>` on either shape would refuse or loop on a non-terminal marker; pointing the user at `findings` opens the recovery loop instead.

Markerless coding rows are not input gates. `2-brainstorm` and `4-execute`
with `:none` now emit `READY_TO_RUN`; `8-finalize` with `:none` emits
`READY_TO_RUN` once `pr.md` exists (missing `pr.md` remains `ERROR`). A stray
`:complete` marker at execute-stage is treated like `:execute_complete` and
surfaces `READY_TO_OPEN_PR`; other unexpected terminal markers at execute-stage
become `ERROR` rather than phantom `NEEDS_INPUT`.

Markerless `6-review` tasks map to `READY_FOR_REVIEW`, not `NEEDS_INPUT`. This matters after a recovery marker is cleared: the next useful action is to run the review stage, while only an explicit `REVIEW_WAITING` marker should open the input-editor path.

## Command emission

Workflow verbs (`brainstorm`/`plan`/`develop`/`open-pr`/`review`/`artifacts`/`finalize`/`archive`) ALWAYS include `--from <stage>`. That's the idempotency lever: a retry after a successful advance fails with `WRONG_STAGE` (4) instead of silently advancing twice.

Generic verbs (`findings`/`accept-finding`/`reject-finding`) include `--stage <stage>` only when slug-stage ambiguity actually exists (`stage_collision: true`).

For non-coding workflows, command emission bypasses the coding
`Hive::Workflows::VERBS` table. `ready_to_advance` emits
`hive approve <slug> --from <descriptor-stage-dir>` and generic run/input rows
emit `hive run <slug>` (plus `--project` when the status snapshot spans multiple
projects, and `--stage` for run rows only when a stage collision was reported).

Human descriptor stages use the dedicated `human_needs_input` classification:
their non-complete marker state is `NEEDS_INPUT` with label
`Awaiting human decision`, no daemon-dispatch command, and a structured
`outcomes` list. The operator transition is deliberately separate from generic
approval:
`hive decide TASK OUTCOME --from STAGE --decision-id DECISION_ID`. A completed human stage
uses the shared `archived` action even though its folder remains in the terminal
human-stage directory. The completing decision writes `completed_at` from the
same clock as its durable decision record, so descriptor retention applies
without a separate human-only completion state. An identical decision retry is
a no-op while stale or conflicting decisions fail against the expected stage
and visit-specific decision ID.

`--project <name>` is appended whenever `project_count > 1` so multi-project status output emits unambiguous commands.

The slug is `Shellwords.shelljoin`-escaped so a slug containing shell metacharacters can't break the suggested command.

`EXECUTE_WAITING` rows with no pending findings delegate their structured `next_action` to `Hive::ExecuteWaitingAction`. That keeps `hive status --json`, `hive run --json`, and TUI Enter behavior aligned for `dirty_worktree`, `branch_mismatch`, `head_not_descendant`, `no_worktree_changes`, and `missing_research_output`.

For execute, `TaskAction` now receives the canonical task projection plus the
migration selection. Marker and shadow modes retain the legacy action (shadow
adds an operator warning on unexplained divergence). Conditions mode uses the
shared gate evaluator, so a superseded compatibility wait cannot override the
current attempt/HEAD. The projection subsystem is also the sole legacy marker
adapter before a baseline; downstream consumers do not invent condition state.

## Consumers

| File | Use |
|------|-----|
| `lib/hive/commands/status.rb` | `annotate_actions` calls `TaskAction.for` per row and routes by `action_key` for grouping. JSON `tasks[].action`/`action_label`/`suggested_command`/`next_action` come from this. |
| `lib/hive/commands/run.rb` | `friendly_command` and `approve_action` delegate; `next_action.command` and `rerun_with` use the workflow form. |
| `lib/hive/commands/approve.rb` | `json_next_action` builds the post-advance command via `TaskAction.for(post_move_task)` so the user lands on a runnable form for the new stage. |
| `lib/hive/commands/decide.rb` | Applies a descriptor-declared human outcome and reports the post-decision action/state. |
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
