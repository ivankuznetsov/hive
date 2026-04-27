# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking changes

- **Stage directories renumbered: `5-pr` → `6-pr` and `6-done` → `7-done`.** Position 5 is reserved for the upcoming `5-review` stage (CI-fix → multi-reviewer → auto-triage → fix → browser-test loop, per `docs/plans/2026-04-25-001-feat-5-review-stage-plan.md`). `5-review` is NOT yet present — `Hive::Stages::DIRS` currently has a numeric gap at position 5 that fills when U9 ships.

  **Upgrade path for users with active hive tasks at the time of upgrade:**

  ```sh
  cd <project-root>
  # If a task is in 5-pr/, move it to 6-pr/
  if [ -d .hive-state/stages/5-pr ]; then
    mkdir -p .hive-state/stages/6-pr
    mv .hive-state/stages/5-pr/* .hive-state/stages/6-pr/ 2>/dev/null || true
    rmdir .hive-state/stages/5-pr
  fi
  # If a task is in 6-done/, move it to 7-done/
  if [ -d .hive-state/stages/6-done ]; then
    mkdir -p .hive-state/stages/7-done
    mv .hive-state/stages/6-done/* .hive-state/stages/7-done/ 2>/dev/null || true
    rmdir .hive-state/stages/6-done
  fi
  ```

  `hive init` on fresh projects creates the new directory layout automatically. The migration is one-shot per project; no auto-migration helper ships in v1.

### Added — `hive tui` (live dashboard + keystroke-driven workflow)

- `hive tui` — full-screen, modal, curses-based dashboard over `hive status`. Polls `Hive::Commands::Status#json_payload` in-process at 1 Hz from a non-daemon background thread; renders rows grouped by `TaskAction` action label across registered projects; dispatches workflow verbs as fresh subprocesses on single-key keystrokes. Human-only — `hive tui --json` is rejected with EX_USAGE (64); agent-callable surfaces stay on `hive status` and the typed verbs.
- Four modes — status grid (default), findings triage (Enter on `review_findings`), agent log tail (Enter on `agent_running`), help overlay (`?`); plus a filter prompt (`/`, Esc clears, Enter commits) and per-project scope (`1`–`9`, `0` clears).
- Verb keystrokes: `b` brainstorm, `p` plan, `d` develop, `r` review, `P` (capital) pr, `a` archive. Pressing a verb on an `agent_running` row whose `claude_pid_alive` is true flashes a hint instead of dispatching, pre-empting `ConcurrentRunError` (exit 75); when the PID is provably dead the verb dispatches normally so `Hive::Lock` can reap the stale lock.
- Findings triage: per-`Space` toggles via `hive accept-finding` / `hive reject-finding` use a quiet subprocess flavor (no screen tear-down) so the screen never flashes; `d` dispatches `hive develop --from 4-execute` via full-screen takeover. Bulk `a` / `r` (rebound from grid-mode archive/review) accept/reject every finding at once. After every toggle the document reloads and the cursor relocates by `(severity, title-prefix)` to handle concurrent rewrites.
- Agent log tail: tails the latest `<state>/logs/<slug>/*.log` file via non-blocking reads driven by the render loop's 100 ms input timeout. Handles inode rotation (re-open new inode), truncation (rewind cleanly), and transient `Errno::*` (swallow + retry). Footer shows `[stale: claude_pid no longer alive]` when the producing agent's PID is dead.
- Terminal hostility: `at_exit` cleanup + SIGHUP cooperative cancellation are installed BEFORE the first `Curses.init_screen` so a crash during init still restores the terminal. Resize handled via injected `KEY_RESIZE` (no Ruby `Signal.trap("WINCH")` per ruby/curses#9). Ctrl+Z suspend / SIGCONT resume rely on ncurses' default handlers. SubprocessRegistry holds the in-flight pgid (or `:placeholder` sentinel) under a `Monitor` so the trap path can reap subprocesses without racing the spawn.
- New runtime gem: `curses ~> 1.6` (production block of `Gemfile`). Stdlib-extracted, ruby-core maintained; ships every primitive needed (`def_prog_mode`/`reset_prog_mode`/`endwin` for subprocess takeover, `KEY_RESIZE` injection, automatic SIGTSTP/SIGCONT). Containerised consumers need `apk add ncurses-dev` / `apt install libncurses-dev`.
- New typed exception: `Hive::NoLogFiles < Hive::Error` (exit code 64 USAGE) — raised by `LogTail::FileResolver.latest` when a slug's log directory contains no `*.log` files yet.

- Five workflow verbs `hive brainstorm`, `hive plan`, `hive develop`, `hive pr`, `hive archive` — each is a single Thor command that resolves a slug or folder, then either runs the target stage's agent (already at target) or promotes from source-stage and runs the target's agent. `--from STAGE` is the idempotency assertion: a retry after a successful advance fails with `WRONG_STAGE` (4) instead of silently advancing twice. `--json` emits a single `hive-stage-action` v1 envelope (success and error). `archive` is idempotent at 6-done.
- `Hive::Workflows` module — single source of truth for the verb→source/target stage map. `VERBS` hash plus `verb_advancing_from(stage_dir)` and `verb_arriving_at(stage_dir)` reverse lookups. `Hive::Commands::StageAction`, `Hive::TaskAction`, `Hive::Commands::Approve`, and `FindingToggle` all delegate so renaming or adding a verb is a one-file change.
- `Hive::TaskAction` — `(Task, Marker)` → action classifier with stable `key` (per `Hive::Schemas::TaskActionKind`), human `label`, and copy-paste `command` for the next step. Powers `hive status` action grouping, the `tasks[].action` JSON field, and `next_action.command` emissions in `hive run`, `hive approve`, `hive accept-finding`, and `hive reject-finding`.
- `Hive::Commands::StageAction` — promote-or-run dispatcher backing the workflow verbs.
- `Hive::Schemas::TaskActionKind` self-derived closed enum mirroring `NextActionKind` — pinned by `test/unit/exit_codes_test.rb`.
- `schemas/hive-stage-action.v1.json` published — draft 2020-12 oneOf success/error.
- `Hive::Commands::Approve#initialize` and `Hive::Commands::Run#initialize` accept a `quiet:` kwarg. When set, the inner command does its work but emits no stdout/stderr (errors still raise typed). Used by `StageAction` so a workflow-verb invocation produces a single unified envelope rather than mixed Approve+Run output.
- `hive findings TARGET [--pass N] [--project NAME] [--json]` — list GFM-checkbox findings in `<task>/reviews/ce-review-NN.md` (latest pass by default; `--pass N` for a specific pass). Read-only; emits text table or single-line `hive-findings` JSON document. Schema version 1.
- `hive accept-finding TARGET [ID...] [--severity S] [--all] [--pass N] [--project NAME] [--json]` — tick `[ ]` → `[x]` on review findings so they are re-injected into the next implementation pass via `Hive::Stages::Execute#collect_accepted_findings`. Selectors (positional IDs, `--severity high|medium|low|nit`, `--all`) are unioned. Atomic write (tempfile + rename), task-lock'd, audit-trail commit on hive/state. Idempotent — already-accepted findings are no-ops and excluded from the `changes` array.
- `hive reject-finding TARGET [ID...] [--severity S] [--all] [--pass N] [--project NAME] [--json]` — inverse: tick `[x]` → `[ ]`. Same selectors, same locking, same idempotency.
- `Hive::Findings` module — parser + writer for review files. `Document` exposes a `findings` list (1-based stable IDs in document order), `summary` (total / accepted / by_severity counts), `toggle!(id, accepted:)`, and atomic `write!`. `review_path_for(task, pass:)` resolves the latest or named-pass review file.
- `Hive::TaskResolver` (`lib/hive/task_resolver.rb`) — extracted slug-or-folder resolution shared between `approve`, `findings`, `accept-finding`, and `reject-finding`. `Hive::Commands::Approve` now delegates to it; future commands can compose on the same resolver.
- `Hive::NoReviewFile` (exit 64 / USAGE) and `Hive::UnknownFinding` (exit 64 / USAGE) typed exceptions; `UnknownFinding` carries the offending `id` for the JSON error envelope.
- `Hive::NoSelection` (exit 64 / USAGE) typed exception for `accept-finding` / `reject-finding` invocations with no IDs, no `--severity`, and no `--all`. Distinct from `InvalidTaskPath` so callers branching on `error_kind` get a precise signal.
- `Hive::Schemas::ErrorEnvelope.build(schema:, error:, error_kind:, extras:)` helper — single source for the JSON error envelope shape. Used by the `findings` and `accept-finding` / `reject-finding` commands; per-error structured fields (`candidates` / `id` / `path` / `stage`) are pulled from the typed exception automatically.
- `Hive::RollbackFailed` (exit 1 / GENERIC) typed exception. Raised by `Hive::CommitOrRollback.attempt!` when the rollback step itself fails after a commit failure. Distinct from a plain `Hive::Error` so the JSON envelope's `error_kind: "rollback_failed"` lets agents distinguish "commit failed but rollback succeeded → fs/git pristine, safe to retry" from "commit failed AND rollback failed → fs/git may be inconsistent, manual intervention needed before retry."
- `Hive::CommitOrRollback.attempt!` module helper — consolidates the dual-rescue rollback pattern shared by `Hive::Commands::Approve#attempt_rollback!` and `Hive::Commands::FindingToggle#rollback_review_change!`. Both call sites now reduce to caller-specific message-builder lambdas plus the helper. Pre-condition checks (e.g. approve's "source path now exists, can't roll back") stay in the caller; the helper owns the rescue + re-raise contract.
- Fenced-code-block awareness in `Hive::Findings::Document#parse_lines`. Triple-backtick (and triple-tilde) fence tracking means `## High` or `- [ ] foo` *inside* a fenced block (e.g. example output in justification) won't accidentally register as a heading or finding. Closes a latent bug that would have surfaced when the reviewer prompt template emits fenced examples.

### Changed (workflow-verbs round)

- `Hive::TaskAction` carve-outs for `:agent_working` (always emits `agent_running` action with `command: nil`) and `:execute_stale` (now emits `findings` command, not `develop` — running develop on a stale execute task would refuse on the non-terminal marker and loop). Closes the agent-loop bug where `hive status --json` advertised a runnable command for a state that was actively running or in recovery.
- `Hive::Commands::Approve#json_next_action` at the final stage now emits `{ kind: NO_OP, reason: "final_stage" }` instead of `kind: RUN` with `hive archive <slug>`. After advancing INTO 6-done, archive's job is done; emitting it again would loop the Done agent.
- Workflow-verb commands emitted by `TaskAction#command` ALWAYS include `--from <stage>` (was: only when `stage_collision` flag was true). The disambiguator is the idempotency lever; emitting it unconditionally means status-suggested commands and `hive run --json` `rerun_with` strings are retry-safe by default.
- After a successful `hive approve --to <stage>`, the `next_action.command` and text-mode `next:` hint name the verb whose target IS the new stage (e.g. `hive plan <slug> --from 3-plan` after advancing into 3-plan), not the verb that advances OUT of it. Calling that command hits StageAction's at-target branch and runs the new stage's agent, which is what you want next; the "advance out" verb would refuse on the non-terminal marker.
- `Hive::Commands::FindingToggle`'s `next_action.command` and text-mode `next:` hint now include `--from <stage>` for the same reason.

### Changed (round 3)

- `hive-findings` and `hive-approve` schemas both gained `rollback_failed` in the `error_kind` enum.
- Tempfile naming in `Hive::Findings::Document#write!` and `Hive::Lock.update_task_lock` now appends `SecureRandom.hex(4)` to the `Process.pid` suffix. Defends against PID reuse-after-crash leaving a stale tempfile that a new process with the same PID would collide with.
- `schemas/hive-findings.v1.json` — published JSON Schema (draft 2020-12) with `oneOf` over `ListPayload`, `TogglePayload`, and `ErrorPayload`. `test/unit/schema_files_test.rb` pins required-key sets and the `error_kind` enum against the producer's emission.
- `hive approve TARGET [--to STAGE] [--from STAGE] [--project NAME] [--force] [--json]` — agent-callable equivalent of shell `mv <task> <next-stage>/`. Resolves bare slugs across registered projects; validates terminal-marker on forward auto-advance; records a `hive/state` commit on each move; emits a `hive-approve` JSON document on success AND a structured error envelope on every failure path under `--json` (schema_version 1).
- `Hive::Stages` — single source of truth for the stage list (`DIRS`, `NAMES`, `SHORT_TO_FULL`, `next_dir`, `resolve`, `parse`). `GitOps`, `Status`, `Run`, and `Approve` all delegate to this module so adding a 7th stage is a one-file change.
- New typed exceptions: `Hive::AmbiguousSlug` (carries structured `candidates`), `Hive::DestinationCollision` (carries `path`), `Hive::FinalStageReached` (carries `stage`). Each surfaces extra fields in the JSON error envelope so callers don't parse stderr prose.
- `Hive::Schemas::NextActionKind::RUN` — new kind emitted by `hive approve --json` so an agent can chain to `hive run <new_folder>` deterministically. Closed-enum membership pinned in `test/unit/exit_codes_test.rb`.
- `Hive::Schemas::NextActionKind::APPROVE` — `hive run --json` now emits `kind: 'approve'` (was `kind: 'mv'`) for `:complete` and `:execute_complete` markers, with a `command: "hive approve <slug> --from <stage>"` field. `MV` stays in the closed enum (per the additive-only policy) but the canonical agent action is now `hive approve`. Back-compat `from` / `to` fields are kept on the next_action object.
- `schemas/hive-approve.v1.json` — published JSON Schema (draft 2020-12) for external consumers. Validates the success payload, the structured error envelope, and the closed `NextAction.kind` enum. `Hive::Schemas.schema_path("hive-approve")` resolves the absolute path. `test/unit/schema_files_test.rb` pins the schema file's required-key set against the producer's emission so drift fails at test time.
- `.hive-state/.gitignore` — `hive init` now bootstraps a gitignore at the .hive-state root that excludes `stages/*/*/.lock`, `stages/*/*/.lock.tmp.*`, `stages/*/*/*.markers-lock`, and `.commit-lock`. Per-task lock metadata (PIDs, process_start_time) is per-process and was previously committed in hive/state on every `hive run` and `hive approve`.
- Symlink hardening on `hive approve`: `resolve_target` realpaths the resolved folder before passing it to `Task.new`, so a slug-named symlink at `.hive-state/stages/<N>/<slug>` pointing to `/tmp/leaked` is rejected at the PATH_RE check instead of being moved as a symlink.
- TOCTOU robustness in `move_task!`: a non-hive process that `mkdir`s the destination between the pre-check and the rename surfaces as `Hive::DestinationCollision` (typed) instead of a bare `Errno::ENOTEMPTY` trace. Direct `File.rename` is wrapped in a rescue for `ENOTEMPTY` / `EEXIST` / `EISDIR`; cross-device moves fall back to `cp_r` + `rm_rf`.
- `Hive::InternalError` (exit 70 / SOFTWARE) — catch-all wrapper for non-`Hive::Error` exceptions in `Approve#call`. With `--json`, a structured envelope is still emitted (no Ruby trace on stderr); without `--json`, the user sees a friendly `hive: internal error: <Class>: <msg>` and a stable exit code instead of an unhandled trace. Closes the silent-failure path where Errno::ENOSPC, SystemCallError, or an unhandled Open3 failure escaped the rescue boundary.

### Changed (P3 hardening — round 3)

- `Approve#record_commit_or_rollback!` rescue narrowed from `StandardError` to `Hive::Error, SystemCallError`. The previous broad rescue was swallowing typed errors (e.g. `Hive::GitError` exit 70) and rewrapping them as generic exit 1, erasing the contract code. Typed errors now re-raise unchanged after rollback so wrappers see the documented exit code.
- `Approve#attempt_rollback!` (extracted) now wraps the rollback `FileUtils.mv` in its own rescue. If the rollback itself fails (cross-device, EACCES, source re-created), both the original commit failure AND the rollback failure surface in one combined message — operator has the full picture for manual recovery.
- `Approve#cross_device_move!` (extracted from `move_task!`) cleans up the partial destination if `cp_r` fails mid-flight (ENOSPC, EACCES on a child file, EIO). Previously a partial copy plus an intact source could leave the next retry hitting a phantom collision with no indication of where the real data lived.
- `Approve#cleanup_orphan_task_lock` now rescues only `Errno::ENOENT` (expected — concurrent process beat us to delete). Other I/O errors propagate so the rollback path runs.
- `Approve#source_has_tracked_files?` now checks `Open3` exit status. A failed `git ls-files` (corrupt index, missing repo) was previously interpreted as "no tracked files," silently skipping the source-side `git add` and leaving a tree-vs-index drift. Now raises `Hive::GitError`.
- `Hive::Stages.parse(dir)` validates `DIRS.include?(dir)` before splitting. `parse("99-foo")` returns nil instead of `[99, "foo"]` so a hand-constructed stage string can't silently slip past validation downstream.
- `Hive::Stages.next_dir(idx)` raises `ArgumentError` for non-integer or `idx < 1` instead of silently returning whatever `DIRS[idx]` gives. Off-by-one bugs surface at the call site rather than as an indistinguishable nil "final stage".
- `Hive::GitOps::STAGE_DIRS` and `Hive::Commands::Status::STAGE_ORDER` aliases removed; both classes now reference `Hive::Stages::DIRS` directly. Closes the half-migration smell flagged in review.

### Added — round 3

- `wiki/modules/stages.md` — wiki page for the new `Hive::Stages` module per the project's convention of one wiki page per code module.
- `test/unit/stages_test.rb` — pins `DIRS` / `NAMES` / `SHORT_TO_FULL` shapes, `resolve` / `next_dir` / `parse` semantics, and the new validation behavior (parse rejects unknown stages, next_dir raises on out-of-range).
- `test/integration/run_approve_test.rb` — rollback-on-commit-failure test (uses a real `pre-commit` hook that exits 1, asserts mv reverses + GitError exit code 70 surfaces) and a paired rollback-also-fails test for the manual-recovery message branch. Plus `--from` mismatch JSON error envelope test, full per-candidate key-set pin on `AmbiguousSlug`. The tautological `test_to_accepts_every_short_stage_name` was deleted (covered by the new unit tests in `test/unit/stages_test.rb`).
- `--from STAGE` on `hive approve`: asserts the task is at the named stage before advancing. Mismatch raises `WrongStage` (4). Idempotency lever for retry loops — a network blip mid-call no longer silently double-advances on the next attempt.
- `bin/hive` rewrites `<cmd> --help` / `<cmd> -h` into `help <cmd>` before Thor dispatch, so the convention agents try first works.
- Thor `enum:` constraint on `--to` and `--from`: invalid stage values fail at parse time before any code in `Approve` runs, and the valid set is listed in `hive help approve` output.

### Changed

- `hive approve` JSON schema: split combined `from_stage` / `to_stage` strings into `from_stage` (bare) + `from_stage_index` + `from_stage_dir` (combined), mirroring `hive-run`'s `stage` / `stage_index` shape. Added `ok`, `noop`, `direction`, `forced`, `from_marker`, `next_action` fields. Schema version stays at 1 (no consumers in the wild yet).
- `hive approve` git commit is now slug-scoped: `git add -A stages/<src>/<slug> stages/<dst>/<slug>` instead of staging the whole parent stage directories. Sibling-task changes in the same stage no longer get swept into the approve commit, fixing audit-trail corruption.
- `hive approve` is now atomic-with-rollback: `with_commit_lock` is acquired BEFORE the move so contention surfaces before any filesystem mutation; `with_task_lock` blocks concurrent `hive run` on the same task; if the commit fails (pre-commit hook abort, lock timeout mid-flight, etc.) the move is reversed and the original error is wrapped in `Hive::Error` so fs and git don't diverge.
- `hive approve` raises `Hive::FinalStageReached` (exit 4, `WRONG_STAGE`) instead of bare `Hive::Error` (exit 1) when asked to advance past `6-done`. Distinguishes "no further stage" from a recoverable destination collision (still exit 1) so retry loops can branch deterministically.
- `hive approve` raises `Hive::AmbiguousSlug` when a bare slug exists at multiple stages within one project (was: silent lowest-stage-wins). The previous heuristic was wrong for the partial-failure-recovery case where the lower stage is the stale leftover. Pass an absolute folder path or `--to` to disambiguate.
- `hive approve --to <current-stage>` is now a clean no-op (exit 0, `noop: true` in JSON) instead of triggering the destination-collision branch.
- `hive approve` text-mode output sends the `next: hive run …` hint to stderr instead of stdout, so a caller piping stdout through `jq` (without remembering `--json`) doesn't get prose mixed with data.
- `hive approve` deletes the per-process `.lock` file at the destination after the move so it isn't tracked in the slug-scoped commit.
- Initial public release of Hive — folder-as-agent pipeline driving a six-stage filesystem state machine.
- CLI commands: `hive init`, `hive new`, `hive run`, `hive status`, `hive approve`.
- Six pipeline stages: `1-inbox`, `2-brainstorm`, `3-plan`, `4-execute`, `5-pr`, `6-done`.
- Orphan-branch state model (`hive/state` checked out as a separate worktree at `<project>/.hive-state/`).
- Per-task `.lock` (with PID-reuse defence via `/proc/<pid>/stat` start time, macOS `ps -o lstart=` fallback) and per-project `.commit-lock` (flock).
- Atomic marker writes (tempfile + rename under a `.markers-lock` sidecar).
- Prompt-injection nonce wrapper (`<user_supplied_<hex16>>…</user_supplied_<hex16>>`) on every stage template.
- SHA-256 integrity checks on `plan.md` and `worktree.yml` around both the implementation and reviewer passes.
- PR body secret-scan in the `5-pr` stage (api-key / AWS / GitHub-token / PEM patterns).
- Runtime claude version check (`Hive::Agent.check_version!`) wired into every active-stage spawn, memoized per `bin` path.
- Wiki knowledge base under `wiki/` with index, architecture, state-model, decisions (ADRs), per-stage and per-module pages.
- CI: GitHub Actions running tests, RuboCop (37signals omakase), Brakeman, and `bundler-audit`.
- Dependabot configuration (bundler weekly, GitHub Actions weekly).
- `--json` output mode for `hive status` and `hive run`. Each emits a single JSON document on stdout with a `schema` + `schema_version` header (current: `hive-status` / `hive-run`, version 1).
- Documented exit-code contract: `Hive::ExitCodes` constants and per-`Hive::Error`-subclass codes mapped through `bin/hive` (0 success, 2 already-initialised, 3 task in `:error`, 4 wrong stage, 64 usage, 70 software, 75 retryable lock contention, 78 config).
- New `Hive::TaskInErrorState`, `Hive::WrongStage`, `Hive::AlreadyInitialized` exceptions for the new exit-code mappings — all three now actually raised by their corresponding call sites (run.rb on `:error` marker; inbox.rb when `hive run` is invoked on `1-inbox/`; init.rb on a second-init).
- `Hive::SCHEMA_VERSIONS` registry: single source of truth for the JSON contract version per schema (`hive-status`, `hive-run`).
- `Hive::Schemas::NextActionKind` closed enum (`EDIT`, `MV`, `RECOVER_STALE`, `NO_OP`, plus `ALL`) shared between the producer (`run.rb`) and the JSON regression tests.

### Changed

- `hive run` exits with code `3` (not `1`) when a stage records a `:error` marker — distinguishes a runner-level failure from an agent-recorded task failure.
- `hive run` on a `1-inbox/` task now raises `Hive::WrongStage` (exit 4) instead of warning + returning 0, so agent callers can branch on the wrong-stage condition.
- `hive init` on an already-initialised project raises `Hive::AlreadyInitialized` (exit 2) through the rescue path; behaviour is identical to the previous bare `exit 2` but the contract now flows through one channel.
- `with_captured_exit` test helper centralised in `test/test_helper.rb` (previously duplicated in **four** integration test files — the `init_test.rb` copy was missed in the first pass).
