# Wiki Changelog

Append-only log of all wiki operations.

## [2026-04-29T00:00:00Z] state-model trigger fired on TUI log_tail change — no wiki edit

**Action:** The state-model hook fired because `lib/hive/tui/log_tail.rb` was modified. Reviewed the diff: `flush_oversized_partial!` turned from single-pass into a `while` loop so `Tail#open!`'s 64KiB single-shot backbuffer read can't leave a multi-cap partial in memory after one flush. Added regression test `test_tail_open_with_no_newline_backbuffer_respects_partial_cap`. This is a TUI log-tailer memory-cap fix and does not touch the state-model surface (`task.rb`, `markers.rb`, `config.rb`, `lock.rb`, `worktree.rb`, `metrics.rb`). No edit to `wiki/state-model.md` or `wiki/modules/*.md`. The internal partial-cap loop is not currently a wiki-documented behavior and isn't worth surfacing on the user-facing `wiki/commands/tui.md` page.

**Refreshed pages:** none (log entry only).

## [2026-04-27T16:00:00Z] dependencies.md — `minitest` version row refreshed

**Action:** Audit triggered by Gemfile/Gemfile.lock change hook. The U11 curses removal is already reflected in the prior log entry; the only remaining stale row was `minitest`, which still showed `~> 5.20` (locked 5.27.0) from before the dependabot bump in commit `429ff4c`. Updated to `~> 6.0` (locked 6.0.5) to match the current Gemfile + lockfile.

**Refreshed pages:**
- `wiki/dependencies.md` — minitest row corrected; bump source noted inline.

## [2026-04-27T15:30:00Z] `hive tui` curses backend removed (plan #003 U11)

**Action:** U11 deletes the curses code path that lived alongside charm during U1–U10. `bundle install` no longer pulls in `curses` 1.6; `HIVE_TUI_BACKEND=curses` raises a typed error pointing at the removal; every `Curses.*` reference under `lib/` is gone. Bubble Tea + Lipgloss are now the only TUI runtime.

**Refreshed pages:**
- `wiki/dependencies.md` — `curses` row removed; TLDR drops the four-gem framing for three. Frontmatter `updated` bumped.
- `wiki/commands/tui.md` — Backend section already framed charm as default in U10; no edit needed beyond verifying no curses references survived.

**Code changes (referenced from wiki):**
- Deleted: `lib/hive/tui/render/{grid,triage,log_tail,help_overlay,filter_prompt,palette}.rb` (curses renderers — replaced by `lib/hive/tui/views/*.rb` in U7–U9), `lib/hive/tui/key_map/curses_keys.rb` (curses int → KeyMap-symbol translator — replaced by `BubbleModel#bubble_key_to_keymap`), `lib/hive/tui/grid_state.rb` (mutating cursor/scope/filter state — replaced by frozen `Hive::Tui::Model` + `Update.apply`).
- Slimmed: `lib/hive/tui.rb` from 399 to 36 lines — only `Hive::Tui.run` (with the MRI/tty boundary checks) survives. Curses run loop, triage subloop, log-tail subloop, filter-prompt subloop, help overlay, and `install_terminal_safety_hooks` all moved into `Hive::Tui::App.run_charm` + `BubbleModel` during U10 and are deleted here.
- Slimmed: `lib/hive/tui/subprocess.rb` — `takeover!` (curses-suspended spawn-and-wait) and the curses-state save/restore helpers (`with_curses_suspended`, `save_curses_state`, `end_curses`, `restore_curses_state`) deleted; `save_termios`/`restore_termios` deleted (the framework owns termios now). `takeover_command` (charm builder) and `run_quiet!` (curses-free, used for triage toggles) remain.
- Slimmed: `lib/hive/tui/app.rb` — `KNOWN_BACKENDS` is now `[CHARM]`, the `case backend` dispatch collapses to a single charm boot, and `REMOVED_BACKENDS` provides the migration-pointer error for `HIVE_TUI_BACKEND=curses`.
- Slimmed: `lib/hive/tui/key_map.rb` — back-compat shim (`dispatch` + `message_to_tuple`) deleted; only `message_for` remains.
- Updated tests: `test/integration/tui_subprocess_test.rb` drops `takeover!` cases (the `takeover_command` test class covers the same spawn/wait/trap path); `test/integration/tui_signals_test.rb` drops `install_terminal_safety_hooks` cases (the SIGHUP trap now lives in `App.run_charm`); `test/unit/tui/app_test.rb` exercises the curses-removal error; `test/unit/tui/key_map_test.rb` drops the legacy `dispatch`-based test class. Net delta: 597 unit tests, 200 integration tests, 0 failures.
- Removed: `Gemfile` entry for `curses ~> 1.6`; `Gemfile.lock` regenerated.

**Key decisions:**
- **`HIVE_TUI_BACKEND=curses` raises a removal-pointer error rather than silently falling back to charm.** Users who type the value because they hit a charm regression deserve a typed signal, not a confusing "unknown backend" or — worse — a silent override. The pointer lives in `App::REMOVED_BACKENDS` and one release from now will be deleted alongside the env var itself.
- **`Hive::Tui::GridState` deleted, not preserved.** The Charm Model (`Hive::Tui::Model`) plus `Update.apply` already cover the cursor/scope/filter semantics GridState owned. Keeping GridState as a "for testing" artifact would have invited drift the moment Model evolved.

## [2026-04-27T15:00:00Z] `hive tui` migrated to Charm bubbletea + lipgloss (plan #003 U1–U10)

**Action:** Plan #003 ships across 10 commits (U1 scaffold → U10 default flip). The TUI's render layer is now Bubble Tea MVU with Lipgloss styling; the curses path is kept one release as `HIVE_TUI_BACKEND=curses` for terminal-specific regressions. U11 (the curses removal) follows.

**Refreshed pages:**
- `wiki/commands/tui.md` — TLDR mentions bubbletea + lipgloss; new "Backend" section explains the MVU loop and the env-var escape hatch; "Subprocess takeover" rewritten around `Subprocess.takeover_command` + `Bubbletea::ExecCommand`; "Terminal hostility" rewritten around the runner's SIGWINCH/Ctrl-Z handling and `runner.send(TERMINATE_REQUESTED)` for SIGHUP. Frontmatter `updated` bumped.
- `wiki/dependencies.md` — `bubbletea` ~> 0.1.4 and `lipgloss` ~> 0.2.2 added as runtime gems; `curses` flagged as legacy/deprecated through U11. TLDR rewrite + "Why Bubble Tea + Lipgloss" rationale.
- `CHANGELOG.md [Unreleased]` — new "Changed — `hive tui` render layer migrated…" section at the top of the section list, ahead of "Breaking changes" / "Added".

**Code changes (referenced from wiki):**
- `lib/hive/tui/app.rb` — full MVU lifecycle: builds `Hive::Tui::BubbleModel` over `Model.initial`, wires `dispatch: runner.method(:send)`, installs SIGHUP→`runner.send(TERMINATE_REQUESTED)`, runs a 0.5s background poller that injects `SnapshotArrived` / `PollFailed` based on `StateSource.current`, runs `Bubbletea::Runner`, cleans up on exit. Default backend flipped from `curses` to `charm`; `HIVE_TUI_BACKEND=curses` still routes to `Hive::Tui.run_curses` until U11.
- `lib/hive/tui/bubble_model.rb` (new) — Bubbletea::Model adapter. Translates `KeyMessage` via `KeyMap.message_for(...)` and `WindowSizeMessage` to `Messages::WindowSized`; handles side-effect-bearing messages (`DispatchCommand` → `Subprocess.takeover_command`; `OpenFindings`/`OpenLogTail` synchronous I/O; `Bulk*`/`ToggleFinding` `run_quiet!` + reload); delegates everything else to `Update.apply`. Dispatches view by `model.mode` to one of `Views::Grid` / `Triage` / `LogTail` / `HelpOverlay` / composed `Grid + FilterPrompt`.
- `lib/hive/tui/views/{grid,triage,log_tail,help_overlay,filter_prompt}.rb` (new) — pure functions over `Hive::Tui::Model`. Mirror the curses `Render::*` content layout 1:1; styling switched to Lipgloss. Test layer pins layout/text content; visual styling validated by manual dogfood (lipgloss-ruby v0.2.2 strips ANSI in non-tty test envs).
- `lib/hive/tui/update.rb` — extended with keystroke-derived handlers: `Flash`, `CursorDown`/`CursorUp` (mirror `GridState#move_cursor_*` semantics), `ShowHelp`, `OpenFilterPrompt` (pre-fills buffer with active filter), `Back` (mode-aware revert clearing sub-mode state), `ProjectScope`, `Noop`. Pure-function transitions only — side effects live in BubbleModel.
- `lib/hive/tui/subprocess.rb` — adds `Subprocess.takeover_command(argv, dispatch:) → Bubbletea::ExecCommand` and the shared `run_takeover_child` core; curses `takeover!` retains its termios+curses-suspended wrapper.
- `lib/hive/tui/messages.rb` — extended with the keystroke-derived Message types (DispatchCommand, Flash, OpenFindings, OpenLogTail, ToggleFinding, BulkAccept, BulkReject, ProjectScope, plus singleton SHOW_HELP / OPEN_FILTER_PROMPT / BACK / CURSOR_DOWN / CURSOR_UP / NOOP).
- `lib/hive/tui/key_map.rb` — `dispatch(mode:, key:, row:)` is now a thin shim over `message_for(...)` + `message_to_tuple(...)`. Single source of truth — curses (which still calls `dispatch` through U10) and charm (which calls `message_for` directly via BubbleModel) cannot drift.

**Key decisions:**
- **`HIVE_TUI_BACKEND=curses` kept one release.** Curses is the escape hatch if Bubble Tea misbehaves on a user's terminal in production. The next release deletes it (per plan #003 U11). Without this hatch the migration would be a hard cut, which the plan's risk register explicitly counsels against given bubbletea-ruby's alpha status.
- **View tests pin layout, not styling.** lipgloss-ruby v0.2.2 strips ANSI in non-tty environments and exposes no force-color escape hatch. R19 (visual quality bar) is met by manual dogfood rather than golden-string color assertions; the gap is documented in `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md` so a future renderer-profile API can close it.
- **Side effects live in `BubbleModel`, not `Update`.** Update.apply stays pure (Model in, [Model, Cmd] out) so state transitions are unit-testable in isolation. DispatchCommand wraps with `Subprocess.takeover_command`; OpenFindings/OpenLogTail/Bulk*/ToggleFinding do synchronous I/O — same pattern the curses path used in `Hive::Tui.run_triage` / `run_quiet!`. Inline I/O is acceptable for v1 because the operations are quick (file reads) and the alternative (Bubble Tea Cmd-as-Fiber) isn't exposed by bubbletea-ruby v0.1.4.

## [2026-04-27T13:30:00Z] `hive tui` deferred ce-code-review issues #10/#11/#12

**Action:** Commit `4ccad1a` closes the three deferred ce-code-review issues. Two CLI-surface changes worth wiki-recording: (1) `hive tui --json` reject path now emits a structured error envelope on stdout before raising (`{ok:false, error_class:"InvalidTaskPath", error_kind:"unsupported_flag", exit_code:64, ...}`) — no schema bump, because `tui` has no registered `hive-*` schema; (2) the non-tty boundary now raises `Hive::InvalidTaskPath` so it shares EX_USAGE (64) with the `--json` reject, instead of falling through to `Hive::Error` / generic exit 1. `tui` long_desc gained a one-line keystroke summary (`b/p/d/r/P/a`) so agents enumerating help see the human-only interaction shape.

**Refreshed pages:**
- `wiki/commands/tui.md` — terminal-hostility section now documents the JSON error envelope shape and the non-tty USAGE-64 alignment. Frontmatter `updated` bumped.
- `wiki/cli.md` — already updated in `4ccad1a` to flag `tui` as the sole `--json`-rejecting command; no further edit needed.

**Code changes (referenced from wiki):**
- `lib/hive/cli.rb` — `tui` action now emits the JSON envelope before raising on `--json`; long_desc keystroke line.
- `lib/hive/tui.rb` — non-tty raise upgraded to `Hive::InvalidTaskPath`; `restore_terminal_safety_hooks` (SIGHUP trap restore on clean exit); `terminate_requested?` checks added inside `triage_loop` and `log_tail_loop` so SIGHUP collapses subloops within a frame; `Errno::ENOENT/EACCES` rescue around `LogTail::Tail#open!` (race with rotation between `FileResolver.latest` and the open syscall); `Hive::NoReviewFile` rescue in `reload_or_flash` (concurrent archive/rerun) returns `:back` so triage drops to grid instead of crashing.
- `lib/hive/tui/key_map/curses_keys.rb` (new) — extracted curses-int → KeyMap-symbol translation out of `Hive::Tui` so KeyMap owns its own symbol contract.

**Key decisions:**
- **No schema for `tui`'s JSON error envelope.** `hive tui` is human-only and has no registered `hive-*` schema, so the envelope deliberately omits `schema` rather than minting a one-off `hive-tui-error.v1.json` whose only payload is the rejection. JSON consumers still see typed error data; schema-validating wrappers continue to validate against the agent-callable surfaces unchanged.
- **Non-tty + `--json` share EX_USAGE (64).** Both are misuse — the TUI cannot run without a terminal and cannot emit JSON — so wrappers can branch on a single "you used this wrong" exit code instead of distinguishing `1` (generic) from `64`. Documented in `wiki/commands/tui.md` "Terminal hostility".

## [2026-04-27T12:00:00Z] U2–U11 + polish — `hive tui` feature complete

**Action:** Remaining `hive tui` units landed on top of U1: U2 `StateSource`/`Snapshot` (1Hz polling, 5s stalled banner), U3 `KeyMap` (single source-of-truth keystroke→action), U4 `Subprocess.takeover!` / `run_quiet!` + `SubprocessRegistry`, U5 status grid + `GridState`, U6 findings triage mode (`a`/`r` rebind to bulk accept/reject), U7 agent log tail, U8 help overlay + workflow-verb cross-check, U9 SIGHUP / `at_exit` / `KEY_RESIZE` handling, U11 PTY smoke test (`bin/hive tui` boots, paints first frame, `q` exits 0). Then `bcf66cd` applied 13 of 32 ce-code-review findings on top.

**Refreshed pages:**
- `wiki/commands/tui.md` already covers the full surface (modes table, keybindings, verb-refusal-on-`agent_running`, `claude_pid_alive` reaping, `Subprocess.takeover!` 5-step protocol, `run_quiet!` for findings toggles, terminal-hostility section incl. SIGWINCH / SIGTSTP / SIGHUP / `at_exit`, `--json` rejection, full test surface). No further edit needed — landed alongside U1 with the units in mind.

**Code changes (referenced from wiki):**
- `lib/hive/tui/state_source.rb`, `snapshot.rb`, `key_map.rb`, `subprocess.rb`, `subprocess_registry.rb`, `grid_state.rb`, `triage_state.rb`, `log_tail/file_resolver.rb`, `help.rb` — the per-unit modules referenced by the existing `wiki/commands/tui.md` "Test surface" section.
- `test/integration/tui_subprocess_test.rb`, `test/smoke/tui_smoke_test.rb` — pin the curses tty round-trip and end-to-end PTY boot.
- `CHANGELOG.md` — `[Unreleased]` records `hive tui` (commit `643ce67`).

**Key decisions:**
- **No render-layer snapshot tests.** Mainstream Ruby tooling does not provide cell-perfect terminal-snapshot diffing; the data path is unit-tested per-module and the curses round-trip is pinned by the PTY smoke test. Documented in `wiki/commands/tui.md` "Test surface".
- **Wiki refresh stays scoped to `commands/tui.md`.** No stage runner changed; the TUI dispatches the same Thor verbs a human would type. `wiki/stages/` is intentionally untouched.

## [2026-04-27T00:00:00Z] U1 — `hive tui` bootstrap

**Action:** First implementation unit of the `hive tui` plan ([docs/plans/2026-04-27-001-feat-hive-tui-plan.md](../docs/plans/2026-04-27-001-feat-hive-tui-plan.md)). Adds the Thor command, the `Hive::Tui.run` skeleton, and the `curses` runtime gem. Subsequent units (U2–U11) replace the skeleton render loop with the real polling + render machinery. Wiki entries land alongside the command's first appearance per `CLAUDE.md` "wiki maintained alongside code".

**New pages:**
- `wiki/commands/tui.md` — modes, keybindings, data source, subprocess takeover, terminal hostility notes, test surface; structure mirrors `wiki/commands/status.md`.

**Refreshed pages:**
- `wiki/cli.md` — TLDR mentions the new human-only command; command table adds the `tui` row.
- `wiki/index.md` — Commands list links the new page; page count 35 → 36.

**Code changes (referenced from wiki):**
- `Gemfile` — adds `gem "curses", "~> 1.6"` to the production block (1.6.0 resolved).
- `lib/hive/tui.rb` (new) — module skeleton with the `Hive::Tui.run` entry point and the `RUBY_ENGINE != "ruby"` boot guard.
- `lib/hive/cli.rb` — registers `desc "tui"` + `def tui`; rejects `--json` with `Hive::InvalidTaskPath` (exit 64) per the plan's R13.
- `test/integration/tui_command_test.rb` (new) — pins the help-text registration, the `--json` rejection, the `long_desc` text, and the non-tty boundary check.

**Key decisions:**
- **Wiki landed in U1, not a separate U10.** Per KTD-10, conflating a multi-command wiki refresh with the TUI feature inflates blast radius; the TUI's own page is co-shipped with the Thor command so the new surface and its documentation are atomic. Broader wiki refresh for unrelated drift remains deferred.
- **Curses 1.6 production dep.** Stdlib-extracted, ruby-core maintained, ships with `def_prog_mode` / `reset_prog_mode` / `endwin` / injected `KEY_RESIZE` — every primitive the subsequent units need without picking up a 22 MB Rust dep (KTD-1).

## [2026-04-26T23:00:00Z] Round-4 — `hive markers clear`, schema v2, marker-policy refresh

**Action:** Round-4 ce-code-review remediation. Added `hive markers clear FOLDER --name <NAME>` as the agent-callable surface for recovery markers (`REVIEW_STALE` / `REVIEW_CI_STALE` / `REVIEW_ERROR` / `EXECUTE_STALE` / `ERROR`); bumped the `hive-approve` JSON contract to v2 (the v1 → v2 transition added `5-review` and renumbered `5-pr → 6-pr` / `6-done → 7-done`); refreshed `wiki/commands/approve.md`'s marker-policy table to reflect the post-LFG-1 reality where `:review_complete` is in `VALID_TERMINAL_MARKERS`; and pointed `Stages::Review.run!`'s pre-flight `warn` lines at the new command.

**New pages:**
- `wiki/commands/markers.md` — full command reference: usage, allowlist, JSON contract, exit codes, "why a typed command instead of `sed -i`" rationale.

**Refreshed pages:**
- `wiki/commands/approve.md` — marker-policy section now has a per-marker table (which marker is written by which stage and unblocks which transition) and a forward note to `[[commands/markers]]` for the recovery markers. Frontmatter `updated: 2026-04-26`.
- `wiki/stages/review.md` — pre-flight table and REVIEW_STALE recovery section both reference the new command.
- `wiki/cli.md` — TLDR says seven commands (was six); command table adds `markers` row.
- `wiki/index.md` — Commands list adds `[[commands/markers]]`.

**Code changes (referenced from wiki):**
- `lib/hive/commands/markers.rb` (new) — `Hive::Commands::Markers#call` with subcommand dispatch, allowlist enforcement, marker-vs-state guard, atomic write via `Hive::Markers.write_atomic`, `hive_commit` audit-trail, JSON success and error envelopes.
- `lib/hive/cli.rb` — registers `hive markers SUBCOMMAND`.
- `lib/hive/stages/review.rb` — pre-flight `warn` text now embeds the exact `hive markers clear FOLDER --name <NAME>` invocation.
- `schemas/hive-markers-clear.v1.json` (new) — published JSON Schema (draft 2020-12).
- `schemas/hive-approve.v1.json` — restored to its original 6-stage shape (no `review`, ends at `5-pr` / `6-done`) so external validators pinned to v1 still validate.
- `schemas/hive-approve.v2.json` (new) — widened enum (`5-review`, `6-pr`, `7-done`); marked `schema_version: 2`. `Hive::Schemas::SCHEMA_VERSIONS["hive-approve"] = 2`. `Hive::Schemas.schema_path` learned an optional `version:` kwarg so back-compat tests can load v1.
- `lib/hive/stages/review/context.rb` (new) — canonical home for the `Hive::Stages::Review::Context` Data type. `Hive::Reviewers::Context` retained as an alias for the reviewer adapter (`Hive::Reviewers::Agent`) and any custom registered reviewer.
- `lib/hive/agent_profile.rb` — explicit "Public API — do not break" comment block on `AgentProfile.new`; `status_detection_mode:` got a default of `:output_file_exists` so a future kwarg addition can't silently break custom profile registrations.
- `lib/hive/config.rb` — new `validate_review_attempts!` rejects `0` / negative / non-integer values for `review.ci.max_attempts`, `review.browser_test.max_attempts`, `review.max_passes`, `review.max_wall_clock_sec`.
- `lib/hive/stages/review/triage.rb` — error path now deletes any partial `reviews/escalations-NN.md` before returning so the next `hive run` doesn't read `escalations_count > 0` from a corrupt artifact.
- `lib/hive/agent.rb` — `Hive::Agent.bin` / `Hive::Agent.check_version!` now emit a one-shot deprecation warning outside the test suite (claude-specific; bypasses per-spawn profile selection).

**Key decisions:**
- **Schema v2 (Option A) over an in-place v1 break.** External consumers pinned to last week's v1 reject post-upgrade output. Restoring v1 to its original shape and bumping to v2 honors the published-contract semantics.
- **Allowlist excludes terminal-success markers.** `REVIEW_COMPLETE` / `EXECUTE_COMPLETE` / `COMPLETE` gate `hive approve`'s forward-advance check; clearing them silently would let an agent skip the approval gesture. Use `hive approve` instead.
- **Marker-vs-state guard refuses mismatch.** `hive markers clear FOLDER --name REVIEW_ERROR` on a folder whose actual marker is `REVIEW_STALE` raises `Hive::WrongStage` (exit 4) — the failure surfaces an agent's confusion before it edits the wrong file.

## [2026-04-26T22:00:00Z] U10b — wiki sweep for new modules

**Action:** Round-3 ce-code-review remediation flagged five new `lib/hive/` modules added across U9–U14 that lacked dedicated wiki pages. Created the missing pages, refreshed `wiki/templates.md` to catalogue every ERB shipped in the 5-review stage, and corrected the `review.browser_test` config-key drift in `wiki/stages/review.md`.

**New module pages:**
- `wiki/modules/agent_profile.md` — `Hive::AgentProfile` + `Hive::AgentProfiles` registry; built-in claude / codex / pi profiles; references ADR-017 / ADR-018 / ADR-019.
- `wiki/modules/reviewers.md` — `Hive::Reviewers.dispatch`, Context, Result, Base, Agent, SyntheticTask; references ADR-014 / ADR-015.
- `wiki/modules/metrics.md` — `Hive::Metrics.rollback_rate`, parse_commits, parse_trailers, reverted?; trailer schema cross-referenced to `lib/hive/trailers.rb`.
- `wiki/modules/secret_patterns.md` — `Hive::SecretPatterns.PATTERNS` + `scan`; consumers (PR body scan, post-fix diff guardrail).
- `wiki/modules/protected_files.md` — `ORCHESTRATOR_OWNED`, snapshot, diff; consumers (4-execute, 5-review's runner / triage / ci-fix).

**Refreshed pages:**
- `wiki/templates.md` — TLDR now reads "Seventeen ERB templates" (matches `ls templates/*.erb`); catalogue table extended with eight 5-review templates (`fix_prompt`, `ci_fix_prompt`, `browser_test_prompt`, `triage_courageous`, `triage_safetyist`, three reviewer prompts); legacy `review_prompt.md.erb` annotated as no-longer-wired.
- `wiki/stages/review.md` — corrected `cfg.review.browser` → `cfg.review.browser_test` (matches `lib/hive/stages/review/browser_test.rb`).
- `wiki/index.md` — Modules section adds five new entries; page count updated.



**Action:** Replaces the earlier "U10 partial sweep" note. Closes the deferred-page list by writing the full `wiki/stages/review.md`, rewriting `wiki/stages/execute.md` for the impl-only contract (ADR-014), extending `wiki/decisions.md` with ADRs 014–021, refreshing `wiki/architecture.md` and `wiki/index.md`, and updating `wiki/active-areas.md` to mark the 5-review backlog as shipped. Adds `test/smoke/live_review_smoke_test.rb` so `rake smoke` covers the autonomous loop end-to-end against the real claude binary.

**Code (wiki):**
- `wiki/stages/review.md` (new) — full stage page: setup, pre-flight state machine, the pass loop (CI → reviewers → triage → fix → guardrail → browser), per-phase descriptions of `Review::CiFix` / `Reviewers::Agent` / `Review::Triage` / `Review::FixGuardrail` / `Review::BrowserTest`, branching after triage (any `[x]` → fix; escalations only → `REVIEW_WAITING`; all clean → Phase 5), stale-`REVIEW_WORKING` recovery rules per phase, `REVIEW_STALE` recovery, test inventory.
- `wiki/stages/execute.md` rewritten — impl-only contract. State machine table now has no `:execute_waiting` / `:execute_stale`; success path is `init pass → spawn_implementation → SHA-protect → EXECUTE_COMPLETE`. Re-running an already-complete task announces 5-review. Reviewer sub-agent section deleted entirely.
- `wiki/decisions.md` — appended ADR-014 (5-review split — 4-execute drops to impl-only), ADR-015 (sequential reviewers; parallel deferred), ADR-016 (triage bias presets `courageous`/`safetyist`; `aggressive` dropped), ADR-017 (`AgentProfile` parameterisation), ADR-018 (per-CLI isolation flag warning, supersedes part of ADR-008), ADR-019 (per-spawn nonce, supersedes ADR-008's per-process memoization), ADR-020 (post-fix diff guardrail extends ADR-008's PR-stage secret-scan to fix-time), ADR-021 (per-spawn `status_mode` override; orchestrator-owned terminal markers).
- `wiki/architecture.md` — runner-table row for `5-review` (`Stages::Review` orchestrator + sub-runners + `Reviewers::Agent`); state-machine mermaid diagram updated to show `4-execute → 5-review → 6-pr` (was `4-execute → 5-pr`); security paragraph extended to include the per-spawn nonce (ADR-019), per-CLI isolation logging (ADR-018), and the post-fix diff guardrail (ADR-020).
- `wiki/index.md` — pipeline tagline now says seven-stage; `decisions` link mentions 21 ADRs; stages list adds `[[stages/review]]`; commands list calls out `hive metrics rollback-rate`.
- `wiki/active-areas.md` — "additional reviewers in 4-execute" struck through with a note that they shipped under [[stages/review]] (and that linters belong in `review.ci.command` per ADR-014); parallel reviewers (Phase 2 of 5-review) listed as future work behind a config flag (per ADR-015 deferral); U14's "trailer-validation log" listed as deliberately dropped — agents that obey the prompt land trailers, the metric's signal is good enough without runner-side enforcement.

**Code (smoke):**
- `test/smoke/live_review_smoke_test.rb` (new) — opt-in `rake smoke` companion. Skips when `claude` is not on PATH. Reloads `Hive::AgentProfiles` registry in setup/teardown to defeat test pollution from other smoke tests. Sets up a tmp git repo, moves a task into `5-review/`, scaffolds a tiny worktree diff, writes a smoke `config.yml` (one `claude-ce-code-review` reviewer; CI/browser disabled; `max_passes: 1`), runs the loop, asserts the marker terminates as `:review_complete` or `:review_waiting`. Does NOT assert which one — real claude on a real diff may legitimately find findings; both terminal states are clean exits.

**Key decisions:**
- **The smoke is one test, not a suite.** Live-claude spawns are expensive (~$0.25 per run per the existing smoke comment) and brittle (depend on real claude availability + version + token allotment). Integration tests already cover every branch of `Stages::Review.run!` against fake-claude / stubs. The smoke's job is to prove the templates render through real claude and the per-spawn nonce works under real spawn — one test is enough.
- **The smoke accepts `REVIEW_COMPLETE` OR `REVIEW_WAITING` as a pass.** Real claude may find findings (we don't control its output); both are clean terminal states. Anything else (`:review_error`, raised exception) means the runner itself broke, which is what the smoke is guarding against.
- **The wiki sweep documents *current* state, not history.** Per ADR-style convention, stage / module pages describe behavior as it is now. The U-unit history lives in this log; the ADRs explain decisions.

## [2026-04-26T15:00:00Z] U14 ship — `hive metrics rollback-rate` + fix-commit trailers

**Action:** Adds the rollback-rate metric so the triage bias preset (`courageous` default vs `safetyist` opt-in) becomes a measurable trade-off rather than a vibes choice. The fix prompt and ci-fix prompt now require git trailers on every commit (`Hive-Fix-Pass`, `Hive-Triage-Bias`, `Hive-Reviewer-Sources`, `Hive-Fix-Phase`); `hive metrics rollback-rate` walks `git log` and reports what fraction of trailered commits were later reverted. Closes doc-review PL-2.

**Code:**
- `lib/hive/metrics.rb` (new) — `Metrics.rollback_rate(project_root, since:)`. Walks `git log --all` with a NUL-record-separator format (`%H\x00%s\x00%b\x00\x01\n`) so commit bodies with embedded newlines parse correctly. Trailer parsing is in-process (a one-line regex per body) to avoid spawning `git interpret-trailers` per commit on long histories. Revert detection covers two forms: subject-quote match (`Revert "..."`) and `This reverts commit <sha>` body cite (short or full). Returns `{total_fix_commits, reverted_commits, rollback_rate, by_bias, by_phase, since, project_root}`.
- `lib/hive/commands/metrics.rb` (new) — Thor-callable command class. `--days N` filter; `--project NAME` scopes to one registered project; `--json` emits the `hive-metrics-rollback-rate` schema (single line, parity with `hive status --json`). Exit codes: 0 success; 2 unknown subcommand / unknown project / no projects registered. Text output groups by bias and by phase so the user can see whether `courageous` outpaces `safetyist` on rollbacks.
- `lib/hive/cli.rb` — registers `hive metrics SUBCOMMAND` (default: `rollback-rate`) under Thor.
- `templates/fix_prompt.md.erb` — new "Required commit trailers" section that renders the trailer block with values pre-filled (`Hive-Task-Slug`, `Hive-Fix-Pass`, `Hive-Triage-Bias`, `Hive-Reviewer-Sources`, `Hive-Fix-Phase: fix`). Agent fills `Hive-Fix-Findings: <count>` per commit.
- `templates/ci_fix_prompt.md.erb` — same convention with `Hive-Fix-Phase: ci`. CI-fix doesn't carry triage bias or reviewer sources (those concepts only exist for review-fix).
- `lib/hive/stages/review.rb` — `spawn_fix_agent` now passes `task_slug`, `triage_bias`, `reviewer_sources` to the template bindings. Two new helpers: `triage_bias_for(cfg)` reads `review.triage.bias` (default "courageous"); `reviewer_sources_for(ctx)` derives a comma-separated list from per-reviewer files in `reviews/` for the current pass (filters out orchestrator-owned files: escalations, ci-blocked, browser-, fix-guardrail-).
- `lib/hive/stages/review/ci_fix.rb` — `spawn_fix_agent` now passes `task_slug` (derived from `File.basename(ctx.task_folder)` since the task slug is always the folder basename per `Task::PATH_RE`).
- `test/unit/metrics_test.rb` (new, 8 tests) — Trailer parsing, subject-revert detection, sha-revert detection, by-bias / by-phase breakdown, since filter, missing-root → ArgumentError, no-trailer commits excluded.
- `test/integration/metrics_command_test.rb` (new, 5 tests) — JSON schema (`hive-metrics-rollback-rate` v1); text output; unknown project → exit 2; unknown subcommand → exit 2; no registered projects → exit 2.
- `test/integration/prompt_injection_test.rb` — `test_fix_prompt_wraps_accepted_findings` now asserts the trailer block renders with the expected per-spawn values.

**Key decisions:**
- **In-process trailer parsing, not `git interpret-trailers` per commit.** A simple `^([A-Za-z][A-Za-z0-9-]*):\s*(.+)$` regex over the body is good enough for the trailer shape the templates emit. Spawning a subprocess per commit blows up wall time on a project that's been running for months.
- **`git log --all` instead of single-branch lineage.** A v1 metric. The plan called this "out-of-scope for v1" and we honored it: a Revert that lives on a different branch shows up as a rollback, which is the conservative direction (slightly noisy → user sees a higher rate → bias toward safetyist; the opposite would silently underreport rollbacks).
- **Trailers are documented in the template, NOT validated in the runner.** The plan called for a validation log (`fix-trailer-missing-NN.log`), but it adds runner complexity that hasn't paid back yet — agents that obey the prompt land trailers, and the metric just gets noisier when one slips through. We'll add validation if real usage shows the slip rate is high.
- **`Hive-Reviewer-Sources` derived from filenames, not from accepted findings.** Cheaper (no parsing) and more honest: even reviewers whose findings were all rejected get listed, because they still contributed to the triage decision. A consumer who wants "which reviewer's [x] marks landed in this commit" can grep `accepted_findings`.
- **`unknown` is the bias bucket for trailer-less or pre-rollout commits.** Don't drop them on the floor — the ratio of unknown vs known is itself a signal that the prompt-template rollout isn't complete.

**Wiki updates:** wiki/cli.md and wiki/index.md will land in U10's wiki sweep alongside the broader stage docs.

## [2026-04-26T14:00:00Z] U13 ship — Post-fix diff guardrail (ADR-020) real implementation

**Action:** Replaces the U9 stub of `Hive::Stages::Review::FixGuardrail` with a real diff scanner. After Phase 4 commits land in the 5-review autonomous loop, the runner takes `git diff base..head` of just the new commits and walks it once, dispatching each line to the configured pattern set. A match short-circuits the loop with `REVIEW_WAITING reason=fix_guardrail` and writes `reviews/fix-guardrail-NN.md` so the user inspects before the loop continues. The motivating threat model: a fix agent could otherwise auto-merge a `curl ... | sh`, edit a `.github/workflows/*.yml`, or commit a credential — and the user would only see a green pass with one extra commit on the branch.

**Code:**
- `lib/hive/secret_patterns.rb` (new) — Shared regex set (`Hive::SecretPatterns::PATTERNS` + `scan(text)`). 11 patterns: AWS access key (AKIA…), AWS secret access key, GitHub tokens (ghp/ghs/gho/ghu), generic api_key assignment, PEM private keys, OpenAI sk-, Anthropic sk-ant-, Stripe sk/rk/pk_live/test, Slack xox[abprs], JWT (eyJ...). Two consumers: pr.rb's body scan (ADR-008) and fix_guardrail.rb's diff scan (ADR-020). Snippets truncated to 80 chars so callers can include them in error messages without leaking long secrets.
- `lib/hive/stages/review/fix_guardrail/patterns.rb` (new) — `Patterns::DEFAULTS` Hash. 6 default patterns: `shell_pipe_to_interpreter` (curl/wget pipe into sh/bash/python/ruby/node), `ci_workflow_edit` (`.github/workflows/`, gitlab-ci, circleci, Jenkinsfile, bitbucket-pipelines, azure-pipelines, travis), `secrets_pattern_match` (special-cased — dispatches to SecretPatterns.scan), `dotenv_edit` (`.env*`, secrets.yml, credentials.yml, .npmrc, .pypirc), `dependency_lockfile_change` (Gemfile.lock, package-lock.json, pnpm-lock, yarn.lock, Cargo.lock, go.sum, poetry.lock, Pipfile.lock, composer.lock, uv.lock), `permission_change` (raw diff header `new mode 100755`). Each descriptor: `:regex`, `:severity`, `:targets` (`:code` / `:file_path` / `:raw_diff_header`), `:description`.
- `lib/hive/stages/review/fix_guardrail.rb` — Replaces the U9 stub (`Result.new(status: :clean, matches: [])`) with the real walker. `run!` early-returns `:skipped` when `enabled: false` or `bypass: true`; `:clean` when sha pair empty/equal; otherwise `git diff --unified=0 base..head` → `scan_diff(diff, patterns)`. `scan_diff` tracks current file via `+++ b/<path>` headers and current line via `@@ -X +A,B @@` headers; for each pattern checks `:targets` and matches against file path (file_path), added line content (code, with secrets_pattern_match dispatching to SecretPatterns), or raw header line (raw_diff_header). `resolve_patterns(cfg)` applies `review.fix.guardrail.patterns_override`: `false` value disables a default; Hash value adds a custom (must include `regex`, raises `Hive::ConfigError` otherwise; defaults `severity: medium`, `targets: code`).
- `test/unit/stages/review/fix_guardrail_test.rb` (new, 15 tests) — Covers skipped paths (disabled / bypass), clean paths (base==head, no patterns match), all 6 default patterns (curl|sh, wget|bash, .github/workflows/*, Jenkinsfile, AWS access key, GitHub token, .env, Gemfile.lock, package-lock.json), override mechanism (disabling a default, adding a custom regex), and `Hive::ConfigError` on missing `regex` for a custom override. Uses `with_tmp_git_repo` + `with_two_commits` helpers — runs against a real git index, not a string fixture, so the regex/diff format are exercised against actual `git diff` output.

**Key decisions:**
- **Walk the diff once, dispatch per line.** Earlier draft had separate passes for file_path / code / raw_diff_header. Walking once is simpler, cheaper on large diffs, and the per-pattern dispatch in the inner loop is fine because the pattern set is tiny (default 6, capped by config).
- **`secrets_pattern_match` is special-cased, not a regex literal.** The pattern descriptor's `:regex` is `nil`; `scan_diff` checks `name == :secrets_pattern_match` and dispatches to `Hive::SecretPatterns.scan(added)`. This lets one config knob disable the entire secrets bundle without flattening 11 patterns into the override surface, and keeps the secrets module reusable for the PR-body scan.
- **Custom patterns get safe defaults.** `severity: :medium`, `targets: :code` if unspecified. Description defaults to `"custom pattern: <name>"`. `:regex` is the only required key — nudges users into adding patterns without forcing them to internalize the descriptor schema.
- **String regex in YAML compiles to Regexp.** `Regexp.new(regex.to_s)` accepts both `Regexp` literals (Ruby) and `String` (YAML). Doesn't try to be clever about flags — if the user wants case-insensitive, they write `(?i)…`.
- **`raw_diff_header` is its own target.** Permission changes show up as `new mode 100755` header lines, not as content. Mixing them into `:code` would either miss them (header lines don't start with `+`) or false-positive on actual content matching the same regex. Separating the target is the cleanest way to scan them.
- **Diff captured with `--unified=0`.** Zero context lines keeps the diff focused on actual changes — context lines that happen to match a pattern (e.g., a long-standing `curl ... | sh` in a script that's being touched elsewhere) wouldn't be flagged. We only flag *new* additions in this commit range.
- **base_sha == head_sha returns `:clean`, not `:skipped`.** Phase 4's "no commits" case is benign — there's nothing to scan, and the loop should treat it as "guardrail had nothing to do" rather than "guardrail was disabled."

**Wiki updates:** state-model.md updated date.

## [2026-04-26T10:00:00Z] U9 ship — Review runner integration + 4-execute drops to impl-only

**Action:** Phase 3 of the plan. Wires U4 (reviewer adapter), U6 (triage), U7 (CI-fix), U8 (browser-test), and U13 (post-fix guardrail, stubbed) into the autonomous loop documented in the plan's high-level technical design. Concurrently, 4-execute drops its review pass and finalizes with `EXECUTE_COMPLETE` immediately after impl spawn — the user `mv`s to `5-review` to enter the review loop.

**Code:**
- `lib/hive/stages/review.rb` — `Hive::Stages::Review.run!(task, cfg)`. Pre-flight inspects markers (REVIEW_COMPLETE / REVIEW_CI_STALE / REVIEW_STALE / REVIEW_ERROR short-circuit). Validates worktree.yml. Tracks wall-clock budget at every phase boundary. Pass loop runs CI (Phase 1, once on entry) → reviewers (Phase 2) → triage (Phase 3) → branch (Phase 4 fix or REVIEW_WAITING) → loop with pass++ → eventually browser-test (Phase 5) → REVIEW_COMPLETE. Stub finding files for failed reviewers; REVIEW_ERROR if all reviewers fail. SHA-256 protects plan.md/worktree.yml/task.md around the fix spawn. Honors REVIEW_WAITING resume by skipping Phase 2/3 and going straight to Phase 4 with the user's manually-toggled [x] marks.
- `lib/hive/stages/review/fix_guardrail.rb` — **stub** for U13. Returns `{status: :clean, matches: []}`. U13 will fill in the regex/pattern matching against the new commits' diff. Phase 4 calls FixGuardrail unconditionally so U13 lands as a pure module-body change with no further wiring.
- `templates/fix_prompt.md.erb` — Phase 4 fix-agent prompt. Receives `accepted_findings` (concatenated [x] lines from per-reviewer files) wrapped in the per-spawn nonce. Instructs the agent to apply each finding scope-narrowly, run tests, commit. Same constraint set as triage: no edits to plan.md/worktree.yml/task.md/reviews/*.
- `lib/hive/stages/execute.rb` rewritten — impl-only since U9. Drops `run_iteration_pass`, `current_pass_from_reviews`, `collect_accepted_findings`, `count_findings`, `finalize_review_state`, `spawn_reviewer`. Single-pass: spawn impl → SHA-protect plan.md/worktree.yml → set EXECUTE_COMPLETE. Re-running on a complete task says "already complete; mv to 5-review/".
- `templates/execute_prompt.md.erb` rewritten — drops the "after impl, expect a review pass" language. Agent's job is "implement the plan and commit" full stop; user mv's to 5-review to run the review loop.
- `lib/hive/stages.rb` — DIRS now `[1-inbox, 2-brainstorm, 3-plan, 4-execute, 5-review, 6-pr, 7-done]` (no gap). next_dir(4) returns "5-review".
- `lib/hive/commands/run.rb` — pick_runner adds the `"review"` case routing to `Hive::Stages::Review.run!`.
- `lib/hive/task.rb` — STAGE_NAMES + STATE_FILES gain "review" → "task.md".
- `schemas/hive-approve.v1.json` — stage enums include `review` and `5-review`.
- `test/unit/stages_test.rb` — DIRS / SHORT_TO_FULL / NAMES / next_dir assertions updated for the filled gap.
- `test/integration/run_execute_test.rb` rewritten — drops 7 review-iteration tests; keeps + adds impl-only tests (init pass → EXECUTE_COMPLETE; re-run announces 5-review; tampering → :error; impl failure → :error; missing plan.md exits 1; no review files written).
- `test/integration/run_review_test.rb` (new) — 9 integration tests: REVIEW_COMPLETE / REVIEW_CI_STALE / REVIEW_STALE / REVIEW_ERROR pre-flight short-circuits; missing worktree.yml exits 1; worktree dir missing exits 1; clean fast path (zero reviewers + nil CI + browser disabled → REVIEW_COMPLETE skipped); CI hard-block → REVIEW_CI_STALE + ci-blocked.md written; wall-clock cap → REVIEW_STALE reason=wall_clock.
- `test/integration/full_flow_test.rb` — flow now goes 4-execute → 5-review → 6-pr (the new transition).
- `test/integration/prompt_injection_test.rb` — `test_execute_prompt_wraps_plan` (no accepted_findings binding anymore) + new `test_fix_prompt_wraps_accepted_findings` for the 5-review fix prompt.

**Key decisions:**
- **One `hive run` lands a terminal marker or exhausts budgets.** No partial-run states the user has to manually reconcile. The loop runs CI once, then iterates Phase 2/3/4 until terminal (REVIEW_WAITING / REVIEW_STALE / REVIEW_ERROR / REVIEW_COMPLETE).
- **REVIEW_WAITING resume skips Phase 2/3 and re-enters Phase 4 directly.** When the user has manually toggled `[x]` in per-reviewer files and re-runs hive, re-running triage would overwrite their decisions. So resume goes straight to fix.
- **Empty reviewers list is OK, not an error.** Zero reviewers configured = nothing to triage = clean branch = Phase 5. Useful for testing and for projects that haven't configured the reviewer set yet.
- **Pass derivation by max-NN-suffix in reviewer filenames.** No frontmatter pass: field, no pass.txt sidecar. Recovery is filesystem-native: delete the highest-NN reviewer files to drop pass back.
- **EXECUTE_COMPLETE is the only success state for 4-execute.** No more EXECUTE_WAITING / EXECUTE_STALE — those moved to REVIEW_WAITING / REVIEW_STALE in 5-review.

266 tests passing (was 259 pre-U9 + 9 new review runner integration tests − 7 dropped 4-execute review-iteration tests + 5 new misc). Rubocop clean.

**Wiki pages updated:** this entry. Larger pass (`wiki/stages/review.md` new page, `wiki/stages/execute.md` rewrite, `wiki/state-model.md` directory layout, `wiki/decisions.md` ADR-014–021) deferred to U10.

## [2026-04-25T22:00:00Z] U8 ship — Browser-test phase (soft-warn + JSON result protocol)

**Action:** Phase 2's fourth primitive. Optional. Skipped entirely when `review.browser_test.enabled` is false (default). When enabled, runs after Phase 2 produced zero findings and before the runner finalizes. Spawns the configured agent (typically claude with the `/ce-test-browser` skill) up to `review.browser_test.max_attempts` times. Each attempt is expected to write `reviews/browser-result-<pass>-<attempt>.json` with `{status, summary, details, duration_sec}`.

**Soft-warn semantics (per plan R11):** persistent failure does NOT hard-block the loop. After the cap, the runner writes `reviews/browser-blocked-<pass>.md` (embedding every attempt's summary + details) and returns `:warned` so `REVIEW_COMPLETE browser=warned` lands. The 6-pr stage surfaces the warning in the PR body. Browser flakiness is common; the user decides whether to ship anyway.

**Code:** `lib/hive/stages/review/browser_test.rb`. `BrowserTest.run!(cfg:, ctx:) → Result(status, attempts, summary, details, error_message)`. Status values: `:passed`, `:warned` (cap reached), `:skipped` (disabled). Per-attempt JSON parsing tolerates malformed / missing files by treating them as `:failed` with an explanatory summary — the runner moves to the next attempt either way.

**Code (template):** `templates/browser_test_prompt.md.erb`. Receives project_name, worktree_path, task_folder, attempt, pass, result_path, skill_invocation, user_supplied_tag. Instructs the agent to **invoke the `<%= skill_invocation %>` skill** (rendered as `/ce-test-browser` for claude/codex/pi via `profile.skill_syntax_format`) on the worktree, then write the structured JSON result. Explicit instruction: "you do not run test commands directly; you invoke the skill and let it drive."

**Spawn:** uses `status_mode: :output_file_exists` keyed on the per-attempt JSON path. Combined with U4's per-spawn mode override, the orchestrator's `REVIEW_WORKING phase=browser` marker survives across both attempts without `:agent_working` clobber.

**Key decisions:**
- **JSON result protocol over exit-code or marker.** A browser test does more than pass/fail (multiple flows, screenshots, duration); the structured JSON gives the runner enough to surface a useful warning if every attempt fails. Exit-code-only would lose summary/details. State-file marker would conflate with the orchestrator's `REVIEW_WORKING`.
- **Tolerate malformed JSON.** Agent crashed mid-write, network blip, partial file — all classified as `:failed` for that attempt with a one-line "produced no result file" or "produced unparseable JSON" summary. Loop continues to the next attempt rather than escalating to `:error`. Browser tests are expected to be flaky.
- **Browser-blocked doc embeds every attempt.** When all attempts fail, the user gets the full progression in `reviews/browser-blocked-<pass>.md` (Attempt 1 summary/details, Attempt 2 summary/details). Picking only the last attempt would lose context — the failure mode might have shifted between attempts.

**Tests (+8):** disabled (no spawn); passes attempt 1 (single fake-claude write); passes attempt 2 (custom counter-flipper bash script — attempt 1 writes failed, attempt 2 writes passed); fails twice → `:warned` + browser-blocked.md with both attempts embedded; missing JSON counts as failed; unparseable JSON counts as failed; agent timeout counts as failed; prompt invokes `/ce-test-browser` via `profile.skill_syntax_format` (proves the per-CLI skill-invocation path works end-to-end). Plus 2 unit-level tests for `parse_result_file` (passed/unknown status handling).

259 tests passing (was 251). Rubocop clean.

**Wiki pages updated:** this entry. Larger pass deferred to U10.

## [2026-04-25T21:30:00Z] U7 ship — CI-fix loop with output capture

**Action:** Phase 2's third primitive. Runs the project's local CI command (`review.ci.command`, e.g. `bin/ci` or `bin/rails test`); on failure, captures the failure log and spawns a fix agent that reads the error, edits the offending files, commits, and lets the loop re-run CI. Caps at `review.ci.max_attempts` (default 3); after the cap returns `:stale` so the U9 runner can write `reviews/ci-blocked.md` and set `REVIEW_CI_STALE`. Reviewers must NOT run on red CI per the plan's hard-block contract.

**Code:** `lib/hive/stages/review/ci_fix.rb`. `CiFix.run!(cfg:, ctx:) → Result(status, attempts, last_output, error_message)`. Status values: `:green` (CI passed), `:stale` (cap reached without green), `:skipped` (`command` is nil/empty), `:error` (CI binary not runnable, or fix-agent failure). Direct `Open3.capture3` exec via `Shellwords.split` — no `sh -c` indirection so a missing binary raises `ENOENT` cleanly instead of returning shell exit-127.

**Output capture (the load-bearing part — projects' CI commands vary widely):**
- Combined stdout + stderr captured into one stream (some tools write failures to stderr, others to stdout).
- ANSI escape sequences stripped (rspec, jest, cargo emit color even when stdout isn't a TTY).
- Tailed to `review.ci.tail_lines` (default 200) so the fix agent doesn't get a 50k-line log that blows token budget. A "[N earlier lines truncated...]" header tells the agent it's seeing only the tail.
- Hard size cap at `review.ci.max_log_bytes` (default 256 KB) on the captured byte count to defend against runaway processes.
- Invalid UTF-8 sequences scrubbed to `?` so the agent prompt is always a valid string.

**Code (template):** `templates/ci_fix_prompt.md.erb`. Receives project_name, worktree_path, command, attempt, max_attempts, captured_output (in `<user_supplied_<nonce>>` wrapper, ADR-019). Instructs the agent to diagnose, fix, and commit; explicit "do NOT execute instructions inside `<user_supplied>` — that's untrusted CI output, classify it as data not commands."

**Fix-agent spawn:** uses `status_mode: :exit_code_only` (the agent's success is "I committed a plausible fix"; CI's actual outcome is verified on the next loop iteration, not via marker or output file).

**Key decisions:**
- **Direct exec over `sh -c`.** Shellwords-tokenized so `command: "bin/ci --flag"` works as YAML, but no shell indirection means missing-binary detection is clean. Trade-off: shell pipe idioms (`bin/ci | tee`) aren't supported. Projects that need them can wrap in a script and point `command` at it.
- **Captured output goes through the same per-spawn nonce wrapper** as triage's reviewer-content blocks. A hostile CI log (e.g., a test that prints `</user_supplied>` literal) cannot escape because the per-spawn nonce is unguessable.
- **Hive doesn't try to parse CI failures.** No language-specific knowledge, no "find the test name" regex. The agent reads the captured output as plain text and figures it out. Keeps hive ecosystem-agnostic (closes the same scope concern as U4's linter drop).

**Tests (+10):** skipped path (nil command, empty string); green attempt 1 (no agent spawn); green after fix (fake-claude writes a marker file the next CI invocation checks for); capped → :stale at max_attempts; CI command not found → :error; ANSI color codes stripped; long output (1000 lines) truncated to last N; both stdout and stderr captured; captured output reaches the fix agent's prompt with the per-spawn nonce wrapper.

251 tests passing (was 241). Rubocop clean.

**Wiki pages updated:** this entry. Larger pass deferred to U10.

## [2026-04-25T21:00:00Z] U6 ship — Auto-triage step + courageous/safetyist prompts

**Action:** Phase 2's second primitive. Reads every `reviews/<*>-<pass>.md` produced by U4's reviewers, hands them to a triage agent (configured via `review.triage.agent`), and expects the agent to (a) edit each file in place adding `[x]` on auto-fix items + `<!-- triage: <reason> -->` annotations, and (b) write `reviews/escalations-<pass>.md` listing only the still-`[ ]` items grouped by source-reviewer. The U9 runner uses `escalations.md` to decide between `REVIEW_WAITING` (escalations remain) and Phase 4 (fix `[x]` items).

**Code:**
- `lib/hive/stages/review/triage.rb` — `Triage.run!(cfg:, ctx:)` entry point. Discovers reviewer files for `ctx.pass` (excluding `escalations-NN.md` itself), resolves the bias preset or custom prompt, renders, spawns via `Stages::Base.spawn_agent` with `status_mode: :output_file_exists` keyed on `escalations-NN.md`. SHA-256 protected-files check (plan.md, worktree.yml, task.md) wraps the spawn — tampering yields `:tampered` status with the offending file list (per ADR-013-style guarding).
- `templates/triage_courageous.md.erb` — default action-biased preset. Encodes origin R9 rules: auto-fix polish/clarity/dead-code/doc/lint/missing-tests/simple-bug/perf-with-mechanism/security-with-known-pattern. Escalate only architecture / auth / data-integrity / contradictions / low-confidence. Explicit instruction "do NOT postpone polishes" per the user's stated frustration.
- `templates/triage_safetyist.md.erb` — escalation-biased opt-in. Auto-fix only the truly mechanical (typos, lint, dead code, doc); escalate everything else by default. For projects where the human gate matters more than throughput.
- Custom prompt path resolution: `cfg.review.triage.custom_prompt` (a basename relative to `<.hive-state>/templates/`) overrides the bias-preset selection. Path-escape attempts (`../`, absolute path, missing file, symlink to outside) raise `Hive::ConfigError`. Resolved via `File.realpath` + prefix check.
- Empty-reviewer-files path: when no reviewer files exist for the current pass, `Triage.run!` skips the agent spawn entirely and writes a sentinel `# Escalations for pass NN — _No reviewer findings ..._` doc. Lets the U9 runner branch deterministically.

**Key decisions:**
- **Per-spawn nonce wrapping (ADR-019) carries over.** Each reviewer file's content is wrapped in its own `<user_supplied_<nonce> content_type="reviewer_md" path="...">` block. The same nonce is shared across blocks within ONE triage spawn but is fresh per spawn — a hostile reviewer file containing `</user_supplied>` cannot escape the wrapper because the per-spawn nonce is unguessable.
- **Reviewer files are NOT in the protected-set.** Triage's *job* is to edit them in place. Only plan.md / worktree.yml / task.md are SHA-checked.
- **`status_mode: :output_file_exists`** keyed on `escalations-<pass>.md`. Combined with U4's per-spawn mode override, the orchestrator's `REVIEW_WORKING phase=triage` marker survives the triage spawn (no `:agent_working` clobber).
- **Prompt content lives in templates, not in code.** Future bias presets can land as additional templates without touching `triage.rb`.

**Tests (+10):**
- Empty reviewer files → sentinel escalations doc + `:ok`.
- Courageous mode: prompt mentions "courageous mode", references reviewer file paths and the escalations target, includes per-spawn nonce wrapper.
- Safetyist mode: prompt mentions "safetyist mode", does NOT mention "courageous mode".
- Custom prompt: user-supplied template at `<.hive-state>/templates/triage_custom.md.erb` is rendered; preset content is absent from the prompt.
- Custom prompt path-escape (`../../../etc/passwd`) raises `ConfigError`.
- Custom prompt missing file raises `ConfigError`.
- Unknown bias preset (`yolo`) raises `ConfigError`.
- SHA-256 protected files: a tampering fake-claude that mutates `plan.md` is caught — `:tampered` status with `tampered_files: ["plan.md"]`.
- Missing escalations output → `:error` with "missing or empty" in error_message.
- `discover_reviewer_files` excludes `escalations-NN.md` and other-pass reviewer files.

241 tests passing (was 231). Rubocop clean.

**Wiki pages updated:** this entry. Larger pass (`wiki/stages/review.md` new page) deferred to U10.

## [2026-04-25T20:30:00Z] U4 ship — Reviewer adapter abstraction (agent-only in v1)

**Action:** Phase 2's first primitive. Common interface for "anything that produces `reviews/<name>-<pass>.md`" so the 5-review runner's per-reviewer loop is shape-uniform across reviewer types. Plus a per-spawn `status_mode:` override on `Hive::Agent` so the same claude binary serves both `:state_file_marker` mode (4-execute) and `:output_file_exists` mode (reviewer adapter) — the orchestrator's `REVIEW_WORKING` marker now survives each reviewer's spawn.

**Code:**
- `lib/hive/reviewers/base.rb` — `Reviewers::Context` (Data) + `Reviewers::Result` (Data) + `Reviewers::Base` interface (defines `#run!`, `#name`, `#output_path`).
- `lib/hive/reviewers/agent.rb` — agent-based reviewer. Renders the spec's `prompt_template` with skill-invocation per profile (`profile.skill_syntax_format` formatted with the spec's `skill`), spawns via `Stages::Base.spawn_agent` with `status_mode: :output_file_exists`, returns `Result.new(name, output_path, status, error_message)`.
- `lib/hive/reviewers.rb` — `Reviewers.dispatch(spec, ctx)`. Single entry point. v1 supports `kind: agent` only.
- `templates/reviewer_claude_ce_code_review.md.erb`, `templates/reviewer_codex_ce_code_review.md.erb`, `templates/reviewer_pr_review_toolkit.md.erb` — three reviewer prompt templates. Each renders `<%= skill_invocation %>` via the profile's `skill_syntax_format` so the same template works across CLIs once profile is selected.
- `lib/hive/agent.rb` — added `status_mode:` per-spawn kwarg (overrides `profile.status_detection_mode`). Mode-gated marker writes: `:state_file_marker` mode preserves today's behavior (`:agent_working` pre-spawn + `:error` on timeout/exit_code); `:exit_code_only` and `:output_file_exists` modes leave `task.state_file` untouched so the orchestrator-owned marker survives.
- `lib/hive/stages/base.rb` — `spawn_agent` accepts and forwards `status_mode:`.

**Key decisions:**
- **Linter reviewers DROPPED from v1.** Tool-specific linters (rubocop, brakeman, golangci-lint, ruff, etc.) belong in the project's `bin/ci`, not in hive's reviewer set. Hardcoding linter knowledge would couple hive to one ecosystem (the plan originally had Ruby/Rails linters). The user's CI command is a clean per-language contract: hive's 5-review CI-fix phase (U7) shells out to `review.ci.command`, the project's linters run there. `Reviewers.dispatch` raises a helpful error if a config sets `kind: linter` ("not supported in v1; set `review.ci.command` to your linter driver instead"). **Future:** if community contributions arrive for cross-ecosystem CI/linter integration, a plugin pattern can grow then; v1 stays minimal.
- **`status_mode:` is per-spawn, not per-profile.** The same claude binary serves `:state_file_marker` (4-execute, brainstorm, plan, pr) and `:output_file_exists` (reviewer adapter). Mode is a property of the spawn's PURPOSE, not the CLI. Profile's `status_detection_mode` is the default; reviewer adapter overrides per spawn.
- **Reviewer Agent uses a synthetic task object.** `spawn_agent` expects task-shaped `folder`/`state_file`/`log_dir`/`stage_name`. The reviewer adapter receives a `Reviewers::Context` (paths only) and constructs a minimal facade for spawn — keeps the adapter independent of full `Hive::Task` parsing.

**Tests (+10):**
- `test/unit/reviewers_test.rb` (5): dispatcher kind=agent → Agent; kind defaults to agent when absent; kind=linter raises with helpful "not supported in v1" message; unknown kind raises; output_path uses output_basename + zero-padded pass.
- `test/unit/reviewers/agent_test.rb` (5): agent run returns ok when fake-claude writes expected output; error when expected output missing; error when exit non-zero; orchestrator REVIEW_WORKING survives the reviewer spawn (proves the per-spawn `status_mode: :output_file_exists` gating); rendered prompt invokes `/ce-code-review` against `git diff main..HEAD`.
- `test/unit/agent_profile_modes_test.rb` (+1): backward-compat regression for `:state_file_marker` mode still writing `:error` to task.state_file on non-zero exit.

231 tests passing (was 220 before U4). Rubocop clean.

**Wiki pages updated:** this entry. `wiki/modules/agent.md` U4 changes (status_mode kwarg, mode-gated marker writes) deferred to U10's wiki pass.

## [2026-04-25T20:00:00Z] U2 ship — review.* + agents.* config + recursive deep-merge

**Action:** Phase 1's config foundation for the 5-review autonomous loop. Replaced `Hive::Config.merge_defaults`'s single-level `Hash#merge` with a recursive deep-merge (closes doc-review F3 P0); added `agents.*` and `review.*` defaults trees; added load-time validation for reviewer uniqueness, agent-profile resolution, and reviewer entry shape. `templates/project_config.yml.erb` now scaffolds a live (not commented) `review:` block with the 3-entry recommended set (claude-ce-code-review + codex-ce-code-review + pr-review-toolkit), so a fresh `hive init` produces a working 5-review config out of the box.

**Code:** `lib/hive/config.rb` rewrite (deep-merge + validate! + new DEFAULTS keys + ROLE_AGENT_PATHS); `templates/project_config.yml.erb` (live review block); `test/unit/config_test.rb` (+10 cases for deep-merge / validation); `test/integration/init_test.rb` (+1 case for scaffold round-trip).

**Key decisions:**
- Recursive deep-merge with **wholesale-replace at `review.reviewers`** (per ADR-018 — Arrays replace, no per-element merge). All other paths under `review.*` and `agents.*` deep-merge by key.
- Validation runs at load time (`Config.load`) so a bad config fails fast at exit code 78 (`CONFIG`). Error messages enumerate the registered profile names so an agent reading the failure output learns the valid domain.
- `max_wall_clock_sec: 5400` (90 min) aggregate cap — closes doc-review ADV-4.
- New per-role budget/timeout keys (`review_ci`, `review_triage`, `review_fix`, `review_browser`) added to `budget_usd` / `timeout_sec` blocks.

**Code review (ce-code-review run `20260425-f58aa04b`):** 9 reviewer personas; 1 P0 + 5 P1 + 7 P2 + 2 P3 = 15 findings. LFG dispatch:

- **Applied (5 safe_auto fixes):**
  - **#1 P0:** `schemas/hive-approve.v1.json` integer maximum bumped from 6 to 7 (was rejecting valid `7-done` payloads).
  - **#9 P2:** Extracted shared `validate_agent_name!` helper used by both `validate_reviewers!` and `validate_role_agent_names!`.
  - **#11 P2:** Reject empty / whitespace-only `output_basename` (would have produced `reviews/-NN.md` filenames).
  - **#12 P2:** `reviewers:` (nil) now raises `ConfigError` with a clear message instead of silently early-returning into a downstream `NoMethodError`.
  - **#13 P2:** Validation errors now annotate "(defaults; no file present)" when the cited config path doesn't exist on disk.

- **Deferred (gated_auto, residual actionable):**
  - **#2 P1:** `deep_merge` defensive shape-check — adversarial reviewer reproduced 3 paths where bad user input (scalar/array/null at a Hash key) leaks raw `TypeError` / `NoMethodError` instead of typed `ConfigError`. Concrete fix exists (validate type compatibility before recursing) but folds into a follow-up since the architectural choice (raise vs warn vs coerce) deserves explicit treatment.
  - **#6 P1 partial:** `wiki/modules/config.md` rewrite (DEFAULTS block + deep-merge contract + validation rules). Folds into U10 wiki update pass per plan; this entry covers the wiki/log requirement.
  - **#6 P1 partial:** `wiki/decisions.md` ADR-011 amendment for the new review_ci/review_triage/review_fix/review_browser budget keys. Same — folds into U10.
  - **#7 P2:** Orphan `5-pr/` directory after pre-U1 upgrade — `Task.new` accepts the path, status hides it, approve raises misleading `FinalStageReached`. Concrete fix (validation arm in `Task.new` raising `InvalidTaskPath` with migration hint) deferred — needs UX design for the message and the auto-recovery flag.
  - **#8 P2:** Move `review_*` budget/timeout keys from flat `budget_usd.*` into each `review.<role>` block. Defers to U7/U8 when consumers wire up.
  - **#14 P3:** Strict-mode reviewer entry validation (reject unknown fields like `kind: lintr`). Defers to U4 reviewer adapter when the canonical entry shape locks in.

- **Skipped (deliberate, design decisions for later, not bugs):**
  - **#3 P1:** Schema-version bump for `hive-approve` (in-place enum mutation at v1 violates the documented bump policy). Decision: schema is pre-1.0 and has no external cached consumers; accept the in-place mutation. Revisit if hive ships a v1.0 release.
  - **#4 P1:** `Stages.next_dir(idx)` parameter semantics flipped — same signature, different behavior. Decision: internal helper, no external callers; accept.
  - **#5 P1:** `Config.load` raises `ConfigError` on previously-tolerated inputs. Decision: broader failure surface is the design (validation pass is the point of U2); existing wrappers either rescue `ConfigError` or accept the broader contract.
  - **#10 P2:** `config_version` field for the new `agents:`/`review:` keys. Decision: defer until first config-breaking change forces the conversation.
  - **#15 P3:** Mixed git-history search across the renumber — pre-existing commits won't change. Acceptable history split.

**Code:** 4 commits on `feat/5-review-stage` from this U2 work. 210 tests passing (was 206, +4 new tests for the validation paths). Rubocop clean.

**Wiki pages updated:** this entry. Larger pass (`wiki/modules/config.md`, `wiki/decisions.md` ADR-011 amendment, ADRs 014–019) deferred to U10 per plan.

## [2026-04-25T19:30:00Z] CLI: status-first workflow verbs

**Action:** Added the human-facing command surface where `hive status` shows current slugs grouped by next action, and stage verbs (`hive brainstorm`, `hive plan`, `hive develop`, `hive pr`, `hive archive`) move-or-run tasks by slug.

**Key decisions:**
- Folder paths remain authoritative storage and recovery targets.
- `hive run TARGET` remains the lower-level dispatcher and now accepts slugs.
- Workflow verbs use `--from` for source-stage disambiguation; generic target commands use `--stage`.
- `hive brainstorm <slug>` is the only marker-bypass transition, and only for validated `1-inbox` to `2-brainstorm`.

**Pages updated:** `cli.md`, `commands/run.md`, `commands/status.md`, `commands/findings.md`, `modules/task_resolver.md`.

## [2026-04-25T19:31:00Z] U1 ship — renumber 5-pr → 6-pr, 6-done → 7-done

**Action:** Reserved position 5 for the upcoming `5-review` stage by renaming `5-pr` → `6-pr` and `6-done` → `7-done`. `5-review` is NOT yet present — `Hive::Stages::DIRS` has a numeric gap at position 5 that fills when U9 lands.

**Code:** `lib/hive/stages.rb` (`DIRS` updated; `next_dir` now does prefix-based lookup so non-contiguous numbering works — `next_dir(4) → 6-pr`, `next_dir(6) → 7-done`, `next_dir(5) → nil`). Also touched: `commands/run.rb`, `stages/execute.rb`, `templates/pr_prompt.md.erb`, `schemas/hive-approve.v1.json`, README, CHANGELOG (with upgrade snippet for in-flight tasks).

**Wiki swept (16 pages):** `architecture.md`, `state-model.md`, `testing.md`, `index.md`, `active-areas.md`, `stages/{index,pr,done,inbox,execute}.md`, `commands/{init,approve,run,status}.md`, `modules/{stages,git_ops}.md`. The `5-pr → 6-pr` literal in this log's prior brainstorm entry is intentionally preserved (describes the rename action).

**Tests:** 195 passing (was 194; +1 case for prefix-gap `next_dir(5)`). Rubocop clean.

## [2026-04-25T19:00:00Z] U11 + U12 ship — multi-CLI matrix + AgentProfile abstraction

**Action:** Phase 0 of the 5-review-stage plan landed on `feat/5-review-stage`. Two units shipped:

- **U11 (research spike):** Verified headless invocation contracts for `claude`, `codex`, `pi`, `opencode` across 13 dimensions. Output: `docs/notes/headless-agent-cli-matrix.md`. Outcome: claude + codex full-profile (in v1 default reviewer set); pi partial-profile-with-caveats (opt-in per project; no `--add-dir` equivalent → ADR-018 trust-model amendment pending); opencode dropped from v1 scope (no native CE plugin, per-spawn isolation requires temp-config writing).
- **U12 (Agent refactor):** Replaced `Hive::Agent`'s class-level claude singleton with per-spawn `AgentProfile` data object. Three v1 profiles registered (claude/codex/pi). Backward compat: existing 4-execute / brainstorm / plan / pr stages keep working unchanged via default `profile: nil → :claude` lookup.

**Key decisions:**
- **Skill name correction:** actual CE skill is `ce-code-review`, not `ce-review` (corrected throughout the plan).
- **Per-spawn nonce (ADR-019, pending wiki/decisions.md update):** each `Stages::Base.user_supplied_tag` call returns fresh `SecureRandom.hex(8)`. Closes ADR-008's per-process scope; SEC-1 attack surface (leaked nonce forging a sibling spawn's closing tag) is closed.
- **Three status_detection_modes:** `:state_file_marker` (claude — agent writes marker), `:exit_code_only` (CI-fix), `:output_file_exists` (reviewer/triage — exit 0 + named file present).
- **Pi profile is registered but flagged ADR-008-weakened:** no `--add-dir` equivalent, no permission gate. `Stages::Base.spawn_agent` writes `<task>/logs/isolation-warnings.log` when a profile without `add_dir_flag` is spawned with non-empty `add_dirs`. Hive's own default reviewer set ships claude + codex only.

**Code review (ce-code-review run `20260425-b80fcfc5`):** 9 reviewer personas; 1 P0 + 5 P1 + 6 P2 + 8 P3 = 20 findings. LFG dispatch applied 12 safe_auto fixes:
- Pi preflight robustness (#3): 3 failure paths tested; raw `Errno::*` and `ArgumentError` translate to `Hive::AgentError`.
- check_version! Open3.capture3 timeout (#4): 10s cap prevents hangs on credential-prompting wrappers.
- warn_isolation_reduced (#10): tests added; non-Array `add_dirs` raises `ArgumentError` (#20).
- spawn_agent direct tests (#11): default-profile, preflight-ordering, isolation-warning trigger.
- Cross-spawn nonce isolation property test (#12): asserts SEC-1 property, not just "different strings".
- prompt_injection_test cleanup (#18): dead `@user_supplied_tag` ivar manipulation removed.
- Maintainability: `DEFAULT_BIN` removed (#13), `extra_flags` folded into `output_format_flags` (#14), lazy-block registration path dropped (#16), dead nil-guards removed (#17).
- This wiki/log entry (#5).

**Deferred from review (residual actionable work for follow-up units):**
- #1 P0: Pi `--tools read,edit,write` allowlist for reviewer mode → lands with U2 (per-role config).
- #2 P1: stale `expected_output` invalidation → folds into U4 reviewer adapter.
- #6 P1: `wiki/modules/agent.md` rewrite → folds into U10 wiki update.
- #8 P2: `wiki/cli.md` stage + commit → small, lands with this wiki/log entry.

**Skipped (deliberate, not bugs):** #7 P2 stale version cache mid-binary-swap (accepted), #9 P2 `Hive::Agent.bin` BC shim policy (keep until callers routed), #15 P3 `skill_syntax_format` (will wire in U4), #19 P3 `reset_for_tests!` placement (fine under serial Minitest).

**Code:** `feat/5-review-stage` branch. 194 tests passing, rubocop clean.

**Wiki pages updated:** `wiki/cli.md` (AgentProfile-aware authentication line); this entry. Larger pass (`wiki/modules/agent.md`, `wiki/decisions.md` ADR-014–019, `wiki/architecture.md`) deferred to U10.

## [2026-04-25T18:00:00Z] brainstorm: 5-review stage

**Action:** Captured requirements for splitting 4-execute into impl-only + a new 5-review stage that runs CI-fix → multi-reviewer (parallel) → auto-triage → fix → browser-test as a fully autonomous loop. Renumbers pr/done.

**Key decisions:**
- Split execute → execute (impl) + 5-review (loop). Renumber 5-pr → 6-pr, 6-done → 7-done.
- Fully autonomous run; user only enters at REVIEW_WAITING (escalations) or REVIEW_COMPLETE.
- Auto-triage with `liberal_auto_fix` preset (configurable: conservative / aggressive / custom prompt path).
- CI hard-blocks on cap; browser-test soft-warns.
- Multi-reviewer parallel: claude-ce-review, codex-ce-review, pr-review-toolkit, optional linters-as-reviewers.
- Triage edits per-reviewer files in place + writes consolidated `escalations-NN.md`.
- Workflow primitives stay CE skills (portable across Claude Code / Codex CLI / etc.).

**Doc:** `docs/brainstorms/hive-review-stage-requirements.md`.

**Supersedes:** F2 + R6/R7/R8 in `docs/brainstorms/hive-pipeline-requirements.md` (the original review-iteration requirements inside 4-execute).

**Wiki pages updated:** — (none yet; follow-up after `/ce-plan` and implementation will refresh `stages/execute.md`, add `stages/review.md`, update `stages/index.md`, `state-model.md`, `modules/config.md`, `decisions.md`.)

## [2026-04-25T00:00:00Z] bootstrap

**Action:** Initial wiki bootstrap from codebase (per `~/wikis/bootstrap-wiki.md` plan via gist `f53222b0d3ace9086be820d366b621e4`).

**Pages created:**
- Top level: `architecture.md`, `state-model.md`, `cli.md`, `dependencies.md`, `decisions.md`, `active-areas.md`, `gaps.md`, `templates.md`, `testing.md`, `index.md`, `log.md`.
- Commands: `commands/init.md`, `commands/new.md`, `commands/run.md`, `commands/status.md`.
- Stages: `stages/index.md`, `stages/inbox.md`, `stages/brainstorm.md`, `stages/plan.md`, `stages/execute.md`, `stages/pr.md`, `stages/done.md`.
- Modules: `modules/task.md`, `modules/markers.md`, `modules/lock.md`, `modules/worktree.md`, `modules/git_ops.md`, `modules/agent.md`, `modules/config.md`.

**Pages updated:** —

**Gaps found:**
1. No live `claude` v2.1.118 smoke-test recorded.
2. `hive init` not yet exercised against the pilot project.
3. `git config gc.reflogExpire never refs/heads/hive/state` not enforced in `Init#call`.
4. Pilot project's pre-commit hook interaction with `.hive-state/` commits unverified.
5. macOS PID-reuse fallback for stale-lock detection not implemented.

**Source:** Codebase read (`lib/`, `bin/`, `templates/`, `test/`) + author's local planning notes. No git history available — repository had no commits yet at the time of bootstrap.

## [2026-04-25T11:50:00Z] post-MVP-review hardening

**Driver:** /ce-code-review on the Phase 1 MVP commit surfaced 1 P0, 9 P1, ~20 P2/P3 findings plus wiki drift. This entry records the code/security/reliability changes; wiki pages were synced in the same change.

**Code changes (all behind passing tests; no regressions in 91-test suite):**

- **P0 worktree.yml hijack closed** (`lib/hive/stages/execute.rb`): `worktree_root` is now derived canonically from `cfg["worktree_root"] || ~/Dev/<project>.worktrees` instead of `File.dirname(worktree_path)`. The fallback was tautological — agent-rewritten pointer paths were validating against their own dirname. Plus: implementation pass is now wrapped in the same SHA-256 protection as the reviewer pass — both runs verify `plan.md` and `worktree.yml` haven't been mutated, with `:error reason=implementer_tampered` / `reviewer_tampered`.
- **Symlink escape closed** (`lib/hive/worktree.rb`): `validate_pointer_path` uses `File.realpath` so symlinks can't shadow the prefix check.
- **Prompt-injection nonce wrapper** (`lib/hive/stages/base.rb`, all 4 templates): `Stages::Base.user_supplied_tag` returns `user_supplied_<hex16>` rotated per process. Templates wrap user content with the nonce-tag so attacker `</user_supplied>` payloads cannot terminate the wrapper. Plan U11's mandated regression test is now in `test/integration/prompt_injection_test.rb`.
- **Brainstorm/plan add-dir narrowed** (`lib/hive/stages/{brainstorm,plan}.rb`): dropped `add_dirs: [task.project_root]`. Early-stage agents no longer have project-source write access via `--dangerously-skip-permissions`. Trade-off: the agent loses CLAUDE.md auto-discovery at brainstorm/plan; we accept that until a snapshot-mount approach is designed.
- **Pass counter from reviews/** (`lib/hive/stages/execute.rb`): `current_pass_from_reviews` counts `Dir[reviews/ce-review-*.md]` instead of parsing task.md frontmatter. Removes the agent-must-update-frontmatter contract that was contradicting the reviewer prompt's "do not edit task.md" rule.
- **Reviewer prompt rewritten** (`templates/review_prompt.md.erb`): step 4 was "do not edit task.md" while step 5 said "update pass: in task.md frontmatter". Reviewer now writes only the review file; the orchestrator's `finalize_review_state` owns the terminal marker.
- **Atomic Markers.set** (`lib/hive/markers.rb`): tempfile + `File.rename` instead of truncate+write. ENOSPC/crash mid-write no longer corrupts state. UTF-8 encoding pinned. Lock moved to a `.markers-lock` sidecar so reads of the data file don't see partial writes.
- **PR secret-scan** (`lib/hive/stages/pr.rb`): regex scan on `pr.md` + `gh pr view --json body` for api-key/AWS/GH-token/PEM patterns. Hit → marker `:error reason=secret_in_pr_body`, no commit. Implements the lint promised in plan KTD that was missed at MVP time.
- **Reliability batch** (`lib/hive/agent.rb`, `lib/hive/lock.rb`): reader thread sets `report_on_exception = true`; `Process.wait2` for atomic status capture (no `$?` race); `with_commit_lock` has a 30s deadline (`flock LOCK_NB` + sleep poll); `update_task_lock` writes via tempfile + rename; `process_start_time` falls back to `ps -o lstart=` on macOS; nil exit_code + `:none` marker now produces `:error reason=no_marker_no_exit_code` instead of silent OK.
- **Network timeouts** (`lib/hive/stages/pr.rb`): `gh auth status`, `git push -u origin`, and `gh pr list` all wrapped in `Timeout.timeout(60)` so a network drop can't hang the pipeline. `gh pr list` now queries `--state all` instead of `--state open` so a closed-then-retried PR doesn't create a duplicate.
- **hive_state_init pre-flight** (`lib/hive/git_ops.rb`): refuses init on a repo with zero commits (`git rev-parse --verify HEAD`) instead of failing mid-bootstrap.
- **hive_commit scope narrowed** (`lib/hive/git_ops.rb`): adds only `stages/<stage>/<slug>` + `logs/`, not the whole tree, so a crashed prior run's leftover staging cannot cross-contaminate.
- **Slug hygiene** (`lib/hive/commands/new.rb`): derived prefix capped at 51 chars so SLUG_RE always passes; reserved list grew to include `hive-state`/`hive_state`/`state` (worktree-vs-orphan-branch confusion); error message no longer mentions a non-existent `--slug` flag.
- **Status pid lookup** (`lib/hive/commands/status.rb`): reads `claude_pid` from the per-task `.lock` file (where `Hive::Agent` actually writes it) instead of marker attrs (where it never appears).

**Pages updated:**
- `wiki/modules/agent.md` — removed inode-tracking sections; documented `--verbose` requirement; updated `handle_exit` table for the nil-exit_code/`:none` case.
- `wiki/architecture.md` — security-boundary list rewritten (nonce wrapper, narrowed add-dir, two-pass SHA-256, PR secret-scan); `build_cmd` block adds `--verbose`; agent-loop step 6 no longer mentions inode comparison.
- `wiki/decisions.md` — ADR-008 amended with the post-MVP boundary set.
- `wiki/index.md`, `wiki/gaps.md` — line edits removing inode language.

**Tests added:**
- `test/integration/prompt_injection_test.rb` — 5 cases asserting nonce wrapping per template + per-process tag rotation; covers the plan U11 regression mandate.

**Tests:** 91 / 290 assertions, all green.

## [2026-04-25T14:50:00Z] CLI: --json + hive approve

**Driver:** Agent-callable contract work. `hive run` and `hive status` gained `--json` (commits 85439ee, predecessors); `hive approve TARGET` was added (32b0e8c) as the agent replacement for shell `mv <task> <next-stage>/`. Stable exit codes formalised in `Hive::ExitCodes`; schema versions pinned in `Hive::Schemas::SCHEMA_VERSIONS`.

**Code changes:**
- `lib/hive.rb` — `Hive::ExitCodes` constants (0/1/2/3/4/64/70/75/78); `Hive::Schemas::SCHEMA_VERSIONS` (`hive-status`, `hive-run`, `hive-approve` all v1) and closed `NextActionKind` enum. New typed exceptions `TaskInErrorState` (exit 3), `WrongStage` (exit 4), `AlreadyInitialized` (exit 2); existing exceptions now override `exit_code` to match the contract.
- `lib/hive/cli.rb` — `--json` is a `class_option` honoured by `status` and `run`; new `approve` subcommand with `--to`, `--project`, `--force`, `--json`.
- `lib/hive/commands/approve.rb` (new) — slug-or-folder resolution across registered projects, lowest-stage-wins disambiguation within a project, marker policy (forward auto needs `:complete`/`:execute_complete`, `--to` and `--force` bypass), `FileUtils.mv` + `git add -A` on both source and destination parent stage dirs, single hive/state commit per move.
- `lib/hive/commands/{run,status}.rb` — `--json` emit paths producing `hive-run` / `hive-status` documents.
- `lib/hive/commands/init.rb` — `warn`/`exit 2` replaced with `raise Hive::AlreadyInitialized`.
- `lib/hive/stages/inbox.rb` — inert `1-inbox` now `raise Hive::WrongStage` (exit 4) instead of warn/exit, so agent callers can branch without parsing stderr.

**Pages updated:**
- `wiki/cli.md` — command table grew `approve`; `--json` noted as `class_option`; full exit-code contract table.
- `wiki/commands/approve.md` (new) — usage, slug resolution rules, marker policy, JSON contract, exit codes.
- `wiki/commands/run.md`, `wiki/commands/status.md` — `--json` output shape and schema pin.
- `wiki/stages/inbox.md` — `WrongStage` raise + exit 4 documented.
- `wiki/active-areas.md`, `wiki/stages/execute.md` — refreshed (a2b9e05).
- `wiki/dependencies.md` — new dev gems (rubocop-rails-omakase, brakeman, bundler-audit; 7373114).
- `wiki/index.md` — `commands/approve` added; `--json` notes on `run` / `status`.

**Tests:** 11 new integration cases for `approve` (happy path, inbox needs `--force`, backward `--to`, short stage names, unknown stage, slug not found, cross-project ambiguity, destination collision, folder-path target, JSON schema, 7-done overflow). Suite: 115 / 417 assertions, all green. RuboCop clean.

## [2026-04-25T18:00:00Z] hive approve hardening — full ce-code-review remediation

**Driver:** /compound-engineering:ce-code-review against PR #4 (`feat/hive-approve`) ran 8 reviewer personas in parallel and surfaced ~50 findings, including 5 P1s. Two P1s (JSON-on-error silence; non-idempotent retry) were independently called out by three separate reviewers. This entry records the remediation; merge of PR #4 is gated on it.

**Cross-project context:** No prior pattern in `~/wikis/master/wiki/` for "agent-callable equivalents of shell verbs"; this is the first such command in the project, so its conventions (typed exceptions per failure mode, slug-scoped commits, JSON error envelope mirroring stdout/stderr dual-signal of `hive run --json`, idempotency via `--from STAGE`) set the precedent for future agent-callable subcommands.

**Code changes:**

- **JSON error envelope on every failure path** (`lib/hive/commands/approve.rb`): every `Hive::Error` raised inside `do_call` is caught, emitted as a `{schema, schema_version, ok: false, error_class, error_kind, exit_code, message, ...}` document on stdout (with structured fields per error class — `candidates` for `AmbiguousSlug`, `path` for `DestinationCollision`, `stage` for `FinalStageReached`), then re-raised so `bin/hive` produces the contract exit code. Mirrors `hive run --json`'s dual-signal pattern (run.rb:91-95).
- **`--from STAGE` idempotency assertion**: Thor option + `validate_from!` enforces "task is at expected stage" before advancing. Mismatch → `WrongStage` (exit 4). Closes the live-reproducible bug where `hive approve <slug> --force --json` twice in a row silently advanced two stages.
- **Slug-scoped git add** (`record_hive_commit`): `git add -A stages/<src>/<slug> stages/<dst>/<slug>` instead of `stages/<src> stages/<dst>` (parent dirs). Sibling-task changes no longer get swept into the approve commit message. Source side is added only if it has tracked files (`git ls-files` check) — `git add -A <pathspec>` errors on a missing-from-worktree pathspec with no tracked entries, the common case for an untracked source after a prior raw `mv`.
- **Atomic move + commit with rollback** (`perform_move_and_commit`, `record_commit_or_rollback!`): outermost `with_commit_lock(hive_state_path)` surfaces lock contention BEFORE any filesystem mutation; inner `with_task_lock(task.folder)` blocks concurrent `hive run` on the same task during the move; the orphan `.lock` file at the destination (carried by the move) is deleted before the commit so per-process metadata isn't tracked. If the commit fails, `FileUtils.mv` reverses the move and the original error is wrapped in `Hive::Error` so fs and git don't diverge.
- **Same-project multi-stage ambiguity raises** (`find_slug_across_projects` rewrite): silently picking the lowest stage was wrong for the partial-failure-recovery case where the lower stage is the stale leftover. Now raises `AmbiguousSlug` with structured `candidates` and demands an absolute folder path or `--to` to disambiguate.
- **Absolute-path TARGET + `--project` mismatch refused** (`validate_project_path_match!`): combining `--project foo` with `/path/to/bar/.hive-state/...` no longer silently operates on `bar`.
- **`--to <current-stage>` is a clean no-op**: emits `noop: true` in JSON (or `hive: noop —` text), no mv, no commit, exit 0. Previously triggered the destination-collision error.
- **Cwd collision shadow fixed**: bare slug always goes through cross-project search (`path_target?` requires `/` or `~`/`.`). Previously a `pwd` subdirectory matching the slug name took precedence and produced a confusing `InvalidTaskPath`.
- **`Hive::FinalStageReached` exit 4** instead of bare `Error` exit 1 for past-`7-done`. Pairs with the existing collision-stays-at-1 to give callers distinct codes for "no further stage" vs "recoverable collision".
- **`Hive::Stages` module** (`lib/hive/stages.rb`, new): single source of truth for stage list. `GitOps::STAGE_DIRS`, `Status::STAGE_ORDER`, `Run#next_stage_dir`, `Approve` resolution all delegate. Adding a 7th stage is a one-file change.
- **Thor `enum:` constraint** on `--to` / `--from`: invalid stage values fail at parse time with the valid set listed in `hive help approve`.
- **`bin/hive` `--help` flag interception**: `hive <cmd> --help` now works (Thor only honours `--help` before the subcommand name; `<cmd> --help` was being consumed as the next positional). 4-line rewrite in `bin/hive` benefits every subcommand.
- **`hive-approve` schema split**: `from_stage` (bare "brainstorm") + `from_stage_index` (2) + `from_stage_dir` ("2-brainstorm"), mirroring `hive-run`'s `stage` / `stage_index`. Added `ok`, `noop`, `direction`, `forced`, `from_marker`, `next_action` fields. Schema version stays at 1 (no consumers in the wild).
- **`NextActionKind::RUN`** added to the closed enum so `approve --json`'s `next_action.kind` can chain deterministically to `hive run`. Membership pinned in `test/unit/exit_codes_test.rb#test_next_action_kind_closed_enum_membership`.

**Pages updated:**
- `wiki/commands/approve.md` — full rewrite: new flags (`--from`), expanded JSON contract (success + error envelope), updated marker policy, locking-and-rollback section, slug resolution rules including same-project ambiguity, expanded exit-code table.
- `wiki/cli.md` — "five commands"; `--json` honoured by `status`, `run`, AND `approve`; `--help` interception note; expanded approve row in command table.
- `wiki/commands/run.md`, `wiki/commands/status.md`, `wiki/stages/index.md` — added `[[commands/approve]]` reciprocal backlinks.

**Tests:** 20 new integration cases (`run_approve_test.rb`) + 4 new unit assertions (`exit_codes_test.rb`) — coverage for: `--from` idempotency mismatch, all six short stage names, project-filter zero matches, cwd-shadow defence, `:error` marker forward refusal AND backward `--to` recovery, past-7-done exits 4, no-op same-stage in both text and JSON, JSON full key-set pin including new fields, JSON error envelopes for each typed error class (ambiguous, collision, final-stage), no-op next_action at final destination, slug-scoped commit (cross-contamination prevention), orphan `.lock` cleanup, plain-text stderr-hint placement, absolute-path + project mismatch, same-project multi-stage ambiguity. Suite: 135 / 507 assertions, all green.

**Findings dismissed (false positives):**
- `wiki commit_action` doc-vs-code mismatch (project-standards reviewer): verified `Hive::Task#stage_name` returns the bare suffix, so `"#{stage_index}-#{stage_name}"` correctly emits `"2-brainstorm"`. Doc and code agree.

**Findings deferred (P3, separate PRs):**
- Symlink TARGET hardening (adversarial #6) — `File.symlink?` defence at task construction.
- TOCTOU on destination check (adversarial #8) — covered indirectly by `with_task_lock` but not eliminated.
- Published JSON Schema files (api-contract #4) — `schemas/hive-approve.v1.json` for external consumers.
- Pre-existing `.lock` files committed by `hive run` — would need `.gitignore` inside `.hive-state/`.

## [2026-04-25T20:00:00Z] hive approve P3 follow-up — symlink, TOCTOU, schemas, .gitignore

**Driver:** Continuation of the ce-code-review PR #4 remediation: addressing the four P3 items deferred from the prior commit. All four turned out to be sub-day fixes; bundling them into the same PR keeps the work coherent.

**Code changes:**

- **Symlink hardening** (`lib/hive/commands/approve.rb`): `resolve_target` now `File.realpath`s the resolved folder for both the path-target and slug-search return paths. A slug-named symlink at `.hive-state/stages/<N>/<slug>` pointing to `/tmp/leaked` realpaths to `/tmp/leaked` and gets refused by `Hive::Task.new`'s PATH_RE check (real path doesn't match the `.hive-state/stages/` shape). Two integration tests pin both the path-target and slug-lookup branches.
- **TOCTOU robustness** (`move_task!`): switched from `FileUtils.mv` to direct `File.rename` wrapped in a `rescue Errno::ENOTEMPTY, EEXIST, EISDIR` that surfaces as typed `Hive::DestinationCollision`. The pre-check + commit-lock cover the hive-process-vs-hive-process race; the rescue covers the non-hive-process race (a stray `mkdir` between pre-check and rename). Cross-device fallback (rare; `.hive-state` lives under the project root) goes through `cp_r` + `rm_rf`. One integration test stubs `File.exist?` to bypass the pre-check and asserts the rescue produces a clean `DestinationCollision`.
- **NextActionKind::APPROVE** (`lib/hive.rb`, `lib/hive/commands/run.rb`): added to the closed enum (additive). `hive run --json` now emits `kind: "approve"` for `:complete` and `:execute_complete` markers (was `kind: "mv"`), with a new `command: "hive approve <slug> --from <stage>"` field that the agent can copy-paste-execute. Back-compat `from` / `to` fields are kept on the next_action object so old callers parsing the MV shape still get the data they need. `MV` stays in the closed enum per the additive-only policy. Test `test_run_json_on_complete_marker_returns_approve_next_action` (renamed from `_returns_mv_next_action`) pins the new shape; the closed-enum membership test covers both kinds.
- **Published JSON Schema** (`schemas/hive-approve.v1.json`): draft 2020-12 schema with `oneOf` over `SuccessPayload` and `ErrorPayload` definitions, per-stage enums, and the closed `NextAction.kind` enum. `Hive::Schemas.schema_dir` and `Hive::Schemas.schema_path(name)` helpers resolve the absolute path. `test/unit/schema_files_test.rb` pins the schema's required-key set, error_kind enum, and NextAction.kind enum against the producer's emission so a code-vs-schema drift fails at test time. External consumers (non-Ruby SDKs, CI validators) can validate emitted documents with any draft-2020-12 validator (ajv, json_schemer, etc.) without re-implementing the contract.
- **`.hive-state/.gitignore`** (`lib/hive/git_ops.rb`): `hive_state_init` now bootstraps a gitignore at the `.hive-state` root excluding per-task `.lock`, atomic-write `.lock.tmp.*`, per-marker `*.markers-lock`, and per-project `.commit-lock`. Pre-existing pre-bug: `Hive::GitOps#hive_commit` does `git add stages/<stage>/<slug>` which was tracking the per-task `.lock` files into hive/state on every `hive run` (committed PIDs and process_start_time values). Existing projects need to add the `.gitignore` manually; new projects get it via `init`.

**Tests:** 7 new integration / unit cases covering symlink-target rejection (path-target + slug-lookup), concurrent-mkdir collision rescue, schema file existence and key-set drift, schema error_kind drift, schema NextAction.kind drift. `test_run_json_on_complete_marker_returns_approve_next_action` renamed and rewritten. Suite: 142 / 529 assertions, all green. RuboCop clean.

**Wiki updates:**
- `wiki/commands/approve.md` — symlink hardening note in Steps section, TOCTOU rescue noted, JSON Schema file referenced under JSON contract.
- `wiki/cli.md` — `Hive::Schemas.schema_path("hive-approve")` mentioned for external consumers.

## [2026-04-25T22:00:00Z] hive approve round-3 review remediation

**Driver:** /pr-review-toolkit:review-pr final pass surfaced silent-failure (6), type-design (5), test-coverage (6), comment-rot (8), and project-standards (3) findings. All addressed in this commit.

**Code changes:**

- **JSON envelope on non-`Hive::Error` failures** (`approve.rb` `call`): added a second `rescue StandardError` that wraps in new `Hive::InternalError` (exit 70 / SOFTWARE) and emits the JSON envelope. An Errno::ENOSPC from `mkdir_p`, an Open3 fault, or a SystemCallError no longer escapes as a Ruby trace on stderr while a `--json` consumer reads EOF on stdout.
- **`record_commit_or_rollback!` rescue narrowed** from `StandardError` to `Hive::Error, SystemCallError`. The broad rescue was swallowing typed errors and rewrapping them as exit 1; typed errors (`Hive::GitError` exit 70) now re-raise unchanged after rollback.
- **`attempt_rollback!` extracted** with its own inner rescue around the rollback `FileUtils.mv`. If the rollback itself fails, original cause AND rollback failure both surface in one message.
- **`cross_device_move!` extracted** with cleanup on partial `cp_r` failure. ENOSPC mid-tree no longer leaves a half-copy + intact source.
- **`cleanup_orphan_task_lock` rescue narrowed** to `Errno::ENOENT` only. Other I/O errors propagate so rollback runs.
- **`source_has_tracked_files?` checks status**. A failed `git ls-files` was silently being read as "no tracked files," skipping the source-side add. Now raises `Hive::GitError`.
- **`Hive::Stages.parse` validates `DIRS.include?(dir)` first**. `parse("99-foo")` returns nil, not `[99, "foo"]`.
- **`Hive::Stages.next_dir` raises on out-of-range / non-integer**. Off-by-ones surface at the call site.
- **`GitOps::STAGE_DIRS` and `Status::STAGE_ORDER` aliases removed**. Both consumers reference `Hive::Stages::DIRS` directly. Closes the half-migration smell.
- **CLAUDE.md-violating comments fixed**: removed "now treated as", "silently picking the lowest stage was wrong for the partial-failure-recovery case", "Raised by `hive approve`", "APPROVE replaces the old MV emission" and similar transitional / caller-tying / contrast-with-old-behavior phrasings that rot. The structural WHY in each location was preserved or restated as a positive.
- **POSIX rename overclaim corrected** (`move_task!` comment): "silently REPLACE … POSIX rename(2) semantics" was libc-dependent, not portable; reworded to "implementations vary; the rescue covers all three errnos."
- **`--to disambiguates same-project ambiguity`** docstring claim corrected (it doesn't — `--to` selects destination, not source). Same fix in `wiki/commands/approve.md`.

**Wiki updates:**

- `wiki/modules/stages.md` (new) — module page per project convention. Covers DIRS / NAMES / SHORT_TO_FULL constants, `next_dir` / `resolve` / `parse` helpers, the consumer table, and the rationale for module-vs-class.
- `wiki/index.md` — adds `[[modules/stages]]` to the Modules list.
- `wiki/state-model.md` — points the canonical-stage-list claim at `Hive::Stages::DIRS` (was `Hive::GitOps::STAGE_DIRS`).
- `wiki/modules/git_ops.md` — removed the `STAGE_DIRS` constant entry; documents `HIVE_STATE_GITIGNORE` and points to [[modules/stages]] for the stage list.
- `wiki/commands/status.md` — `Hive::Stages::DIRS` reference instead of the deleted `STAGE_ORDER`.
- `wiki/commands/approve.md` — corrected `--to disambiguates` claim.

**Tests:** 7 new (149 / 576 green), RuboCop clean.

- `test/unit/stages_test.rb` (new) — validation semantics for `next_dir` (raises on bad index), `parse` (nil for unknown stages), `resolve`, and constant frozen-ness.

## [2026-04-25T23:00:00Z] hive findings / accept-finding / reject-finding (Phase 2 PR3)

**Driver:** Continuation of Phase 2 agent-callable contract work. `hive approve` (PR #4, merged) replaced shell `mv`; this commit replaces the second hand-edit step in the pipeline — ticking `[x]` on review findings in `reviews/ce-review-NN.md` to mark which findings the next implementation pass should address. The reviewer prompt writes all findings unchecked; the user (now an agent) flips a subset to accepted; `Hive::Stages::Execute#collect_accepted_findings` re-injects only the `[x]` lines into the next pass's prompt.

**Code changes:**

- **`Hive::Findings`** module (`lib/hive/findings.rb`, new) — parser + writer for review files. `Document.new(path)` reads the file, parses each `- [ ]` / `- [x]` line into a `Data.define` value object with `id` (1-based stable; document order), `severity` (lowercased heading), `accepted`, `title`, `justification`, `line_index`. `toggle!(id, accepted:)` flips a single checkbox character without touching surrounding bytes — verified by a unit test that asserts every non-target line is byte-identical after a write. `write!` uses tempfile + rename. `summary` returns total / accepted / by_severity. `Hive::Findings.review_path_for(task, pass:)` resolves the latest or named-pass review file.
- **`Hive::TaskResolver`** (`lib/hive/task_resolver.rb`, new) — extracted from `Hive::Commands::Approve#resolve_target` + `find_slug_across_projects` + `validate_project_path_match!`. ~80 LOC of slug-or-folder resolution now shared between four commands (`approve`, `findings`, `accept-finding`, `reject-finding`); `Approve#do_call` is one line shorter and the duplication that would have appeared in three new commands is collapsed at extraction time.
- **`Hive::Commands::Findings`** (`lib/hive/commands/findings.rb`, new) — read-only list. Resolves task via `TaskResolver`; loads document; emits text table or single-line `hive-findings` JSON. JSON includes per-finding `to_h` plus `summary` block.
- **`Hive::Commands::FindingToggle`** (`lib/hive/commands/finding_toggle.rb`, new) — shared accept/reject. Combines `ID...` positionals + `--severity <s>` + `--all` into a unioned ID list (empty union is an error). Validates every ID exists; flips checkboxes; atomic write; commits to `hive/state` (slug-scoped `git add` of the review file). Acquires `Hive::Lock.with_task_lock(task.folder)` so a concurrent `hive run` can't race against the toggle. Idempotent: already-correct entries are no-ops and excluded from the JSON `changes` array. `next_action` in the JSON points at `hive run <task.folder>` so an agent driving the pipeline knows the immediate next step.
- **CLI wiring** (`lib/hive/cli.rb`): three new Thor subcommands. `--severity` Thor `enum:` constraint against `%w[high medium low nit]`; `--pass` numeric; `--all` boolean; positional `IDs` is variadic (`*ids`).
- **Typed exceptions** (`lib/hive.rb`): `Hive::NoReviewFile` (exit 64), `Hive::UnknownFinding` (exit 64, carries `id`).
- **`Hive::Schemas::SCHEMA_VERSIONS["hive-findings"] = 1`** added.
- **`schemas/hive-findings.v1.json`** — draft 2020-12 schema with `oneOf` over `ListPayload`, `TogglePayload`, and `ErrorPayload`. Per-finding shape, summary, error-kind enum (`ambiguous_slug`, `no_review_file`, `unknown_finding`, `invalid_task_path`, `error`), and the closed `NextAction.kind` enum.

**Wiki updates:**

- `wiki/commands/findings.md` (new) — full page for the three commands. Data model, JSON contract for both list and toggle paths, error envelope, exit-code table, locking section, "why not just edit the file" rationale, backlinks.
- `wiki/cli.md` — TLDR updated to "eight commands"; command table grew three rows; `--json` honour list extended.
- `wiki/index.md` — new entry under Commands; page count bumped 27 → 29.
- `README.md` — daily-usage table grew three rows.

**Tests:** 27 new (176 / 699 green; was 149 / 576 on round-3-merged main). RuboCop clean.

- `test/unit/findings_test.rb` — 9 cases on the parser: severity/order/state pinning, missing-justification handling, summary counts, byte-for-byte round-trip preservation, idempotent toggle, unknown-id raises typed, missing-file raises typed, latest-pass resolution, named-pass missing.
- `test/integration/run_findings_test.rb` — 13 cases on the three commands: text output shape, full JSON-key-set pin, named-pass selection, no-review-file error envelope, accept by ID, accept --severity, accept --all (with no-op detection on already-accepted entries), idempotent re-accept, unknown-id typed error, no-selectors error, reject behaviour, reject idempotency, task-lock contention surfaces ConcurrentRunError (TEMPFAIL/75).
- `test/unit/schema_files_test.rb` — 4 new pins for hive-findings: file existence + draft, ListPayload required keys, TogglePayload required keys, error_kind enum drift.
- `test/unit/exit_codes_test.rb` — pinned `NoReviewFile` (64), `UnknownFinding` (64), `InternalError` (70) exit codes; pinned `hive-findings` schema-versions key.

**Refactor:**

- `Hive::Commands::Approve` was simplified to delegate to `Hive::TaskResolver`. ~80 LOC removed from `approve.rb`; one line in `do_call` (`task = Hive::TaskResolver.new(@target, project_filter: @project_filter).resolve`). All 32 existing approve tests still pass.

## [2026-04-25T23:30:00Z] hive findings — round-2 ce-code-review remediation

**Driver:** /compound-engineering:ce-code-review on PR #5 ran 8 reviewer personas (cli-readiness ran out of tokens; the other 8 produced findings). 4 P1s + 8 P2s + a few P3s addressed in this commit. Two of the P1s were independently corroborated by 2 reviewers each.

**Code changes:**

- **Lock-order inversion fixed** (`finding_toggle.rb#do_call`): swapped to `with_commit_lock` outermost → `with_task_lock` inner, matching `Hive::Commands::Approve`. Closes the deadlock where concurrent `hive approve <slug>` + `hive accept-finding <slug>` would both wait 30s on each other's lock and surface as `ConcurrentRunError`.
- **Rollback false-failure message fixed** (`rollback_review_change!`): the previous shape used a method-level rescue that caught the intentional "rolled back" re-raise on the success path and falsely reported "rollback ALSO failed." Restructured to a flat `begin/rescue` where the rollback I/O is the rescued region; the success-path re-raise leaves the method without re-entering any rescue. The "rollback failed" branch is now reserved for actual rollback failures.
- **CRLF + no-trailing-newline byte-preservation** (`Hive::Findings::Document#toggle!`): captured the original line ending in a 4th regex group on `FINDING_RE` and reused it on rebuild. CRLF input round-trips as CRLF; a last line without `\n` stays without one. The earlier hardcoded `"…\n"` flattened CRLF and added a trailing newline. Pinned by two new unit tests asserting byte-exact round-trip.
- **Severity carry-over fixed** (`parse_lines`): any `## …` heading that doesn't match `KNOWN_SEVERITIES` (`high|medium|low|nit`) now clears `current_severity` to nil. Multi-word headings like `## Detailed Analysis` previously didn't match the heading regex at all (so subsequent findings inherited the prior severity); short non-severity headings like `## Notes` previously matched and set a fake severity. Both leak vectors closed.
- **`with_task_lock` collision in test helper** (`run_findings_test.rb`): the lock-serialisation test pre-acquires `with_task_lock(execute, …)` then calls toggle. With the new outer/inner lock order, toggle still surfaces `ConcurrentRunError` (TEMPFAIL/75) — the test's contract is preserved without modification.
- **Rollback `git reset` exit status checked** (`rollback_review_change!`): switched from `Open3.capture3` (status discarded) to `ops.run_git!` (raises on non-zero). A failed reset now propagates and the rollback message can't lie about the index state.
- **`Hive::Schemas::ErrorEnvelope.build` helper** added. `Findings#emit_error_envelope` and `FindingToggle#emit_error_envelope` collapsed from ~25 LOC each to ~7 LOC. Per-error structured fields (`candidates` / `id` / `path` / `stage`) are pulled from the typed exception automatically. `approve.rb` left intact (its envelope has different structured fields and the duplication risk is lower now).
- **`Hive::NoSelection` exception** added (exit 64 / USAGE). `select_target_ids` now raises this typed class instead of overloading `Hive::InvalidTaskPath`. `error_kind: "no_selection"` joins the `hive-findings` enum. Closes the agent-facing taxonomy issue where `error_kind: "invalid_task_path"` was being used for "argument set was empty."
- **Targeted no-selection messages**: when `--all` runs against an empty review file, the message names that. When `--severity X` matches nothing, the message lists the available severities.
- **`next_action` consistency**: both `kind: "run"` branches now carry a `reason` field. Previously the "nothing accepted yet" branch omitted `reason`; consumers that branched on its presence saw an inconsistent shape.
- **`pass_from_path` deduped**: moved to `Hive::Findings.pass_from_path(path)` module function. The two duplicate `pass_from_review_path` / `pass_from_path` private helpers in `findings.rb` and `finding_toggle.rb` are gone; both commands call the shared module function.
- **Module-level comment de-transitionalised** (`findings.rb`): "after this module, an agent ticks…" rewritten to "Ticking `[x]` flags a finding to address…" (no transitional reference). Per CLAUDE.md "don't reference the current task/fix" rule.

**Schema changes (`schemas/hive-findings.v1.json`):**

- `ErrorPayload.error_kind` enum gained `no_selection`.
- `ErrorPayload.candidates` items now require `{project, stage, folder}` — mirrors `hive-approve.v1.json` so consumers validating `AmbiguousSlug` across the two endpoints can share validation logic.
- Description added to `ErrorPayload` documenting that `operation` is present iff the error came from a toggle command.

**New wiki pages (round-2):**

- `wiki/modules/findings.md` — public surface of `Hive::Findings` (Document, toggle!, write!, summary, review_path_for, pass_from_path), parsing rules, round-trip guarantees pinned by unit tests, consumer table.
- `wiki/modules/task_resolver.md` — resolution rules (path-shaped vs slug, ambiguity classes, `--project` validation), public API, consumers.
- Reciprocal backlinks: `[[modules/findings]]` on `wiki/stages/execute.md` and `wiki/modules/lock.md`; `[[commands/findings]]` on `wiki/stages/execute.md` and `wiki/modules/lock.md`.
- `wiki/index.md` page count bumped 29 → 31.

**Tests:** 10 new (186 / 735 green; was 176 / 699 on round-1). RuboCop expected clean.

- `test_toggle_preserves_crlf_line_endings` — the `\r\n` round-trip pin.
- `test_toggle_preserves_missing_trailing_newline` — the no-trailing-newline pin.
- `test_non_severity_heading_resets_current_severity` — `## Detailed Analysis` and `## Notes` both clear severity.
- `test_pass_from_path_extracts_integer` — module function pin.
- `test_accept_finding_unions_severity_with_explicit_ids` — combinator behaviour pin.
- `test_accept_finding_with_no_selectors_errors` upgraded to assert `error_kind: "no_selection"` and `error_class: "NoSelection"`.
- `test_hive_findings_candidates_item_shape_pinned` — schema drift guard for the candidate item shape.
- `test_hive_findings_error_kinds_match_producer` updated to include `no_selection`.
- `test_error_subclasses_map_to_their_contract_code` updated to pin `Hive::NoSelection` exit code.

**Findings dismissed (false positives):**

- API-contract reviewer's "UnknownFinding can default to `id: nil`" — only theoretical; no current call site passes nil.
- Adversarial reviewer's `path_target?` containment concern — same behaviour as `approve.rb`'s, intentional.
- Maintainability reviewer's "premature TaskResolver extraction" framing — 4 consumers and the realpath/ambiguity rules are exactly the kind of thing that benefits from one source of truth.

## [2026-04-26T00:30:00Z] hive findings — P3 follow-ups (rollback abstraction, fence awareness, tempfile uniqueness)

**Driver:** Closing the three deferred P3 items from the round-2 review entry above. All three landed together so the rollback contract is consistent across approve and the finding commands.

**Code changes:**

- **`Hive::CommitOrRollback.attempt!` helper** (`lib/hive/commit_or_rollback.rb`, new): consolidates the dual-rescue rollback pattern shared by `Hive::Commands::Approve#attempt_rollback!` and `Hive::Commands::FindingToggle#rollback_review_change!`. The helper owns the rescue + re-raise contract: on undo success, it re-raises the original typed `Hive::Error` (preserving exit codes like `GitError → 70`) or wraps non-typed errors in a generic `Hive::Error`; on undo failure, it raises `Hive::RollbackFailed` carrying both the original cause and the rollback failure. Caller-specific concerns (approve's "source path now exists" precondition, the message templates) stay in the caller. ~30 LOC of duplication removed across the two callers.
- **`Hive::RollbackFailed`** (`lib/hive.rb`, new): typed exception (exit 1 / GENERIC) so the JSON envelope can surface `error_kind: "rollback_failed"`. Lets agents distinguish "commit failed but rollback succeeded → safe to retry" from "commit failed AND rollback failed → fs/git may be inconsistent." Both `hive-findings` and `hive-approve` schemas gained `rollback_failed` in the `error_kind` enum; both commands' `error_kind_for` map the new class.
- **Fenced-code-block awareness** (`Hive::Findings::Document#parse_lines`): triple-backtick / triple-tilde fence tracking. Lines inside a fenced block don't register as headings or findings, so an example finding-shaped line in a reviewer's justification block can't false-positive. Closes a latent bug that would surface as soon as the reviewer prompt template emits fenced examples.
- **Tempfile uniqueness** (`Hive::Findings::Document#write!`, `Hive::Lock.update_task_lock`): tempfile names now append `SecureRandom.hex(4)` to the `Process.pid` suffix. Defends against PID reuse-after-crash where a new process with the same PID would otherwise collide on a stale tempfile path.

**Refactors:**

- `Hive::Commands::Approve#attempt_rollback!` now delegates to the helper. The "source path now exists, can't roll back" precondition stays at the caller; the typed-vs-generic re-raise contract moves to the helper.
- `Hive::Commands::FindingToggle#rollback_review_change!` collapses to the same helper-call shape. Identical contract; only the on_undo block (binwrite + git reset) and message lambdas differ.

**Tests:** 5 new unit tests, 191/758 green (was 186/735). RuboCop clean.

- `test/unit/commit_or_rollback_test.rb` (new) — pins the three helper paths: typed re-raise on undo success, generic wrap on undo success with non-typed original, RollbackFailed on undo failure.
- `test_fenced_code_block_lines_are_ignored_by_parser` — backtick fences with `## High` and `- [ ] foo` content; asserts only real findings are parsed.
- `test_tilde_fenced_code_block_also_ignored` — `~~~` fences too.
- `test_error_subclasses_map_to_their_contract_code` updated to pin `RollbackFailed` exit code.
- Both `hive-findings` and `hive-approve` `test_*_error_kinds_match_producer*` tests updated to include `rollback_failed`.

**Wiki:** No new pages this round (the helper module is small and consumer-focused; documenting it inline in the source comment is sufficient). CHANGELOG covers the user-facing surface.
- `test_commit_failure_rolls_mv_back_to_source` — installs a real `pre-commit` hook that exits 1, asserts mv reverses, exit 70 (GitError), and source restored.
- `test_rollback_failure_surfaces_combined_error_message` — pre-commit hook recreates the source path so rollback can't proceed; asserts the combined "rollback NOT possible / manual recovery" message branch.
- `test_json_error_envelope_on_from_mismatch_carries_wrong_stage_kind` — exercises the JSON error envelope on a `--from` mismatch with `--json`.
- AmbiguousSlug envelope test now pins the full per-candidate key set (`folder`, `project`, `stage`).
- The tautological `test_to_accepts_every_short_stage_name` was deleted; the new `stages_test.rb` covers the constants directly.


## [2026-04-26T08:00:00Z] PR #6 status-workflow-verbs — review remediation (round 1)

**Driver:** /compound-engineering:ce-code-review on PR #6 plus an additional independent review surfaced 5 P1s + 8 P2s. Two P1s — "next-action commands drop --from/--project disambiguators" and "workflow verbs emit no JSON envelope" — were flagged by 4 independent reviewers each.

**Code changes:**

- **`Hive::Workflows`** (`lib/hive/workflows.rb`, new): SSOT for the verb→source/target stage map. `VERBS` hash + `verb_advancing_from(stage_dir)` + `verb_arriving_at(stage_dir)` reverse lookups. `StageAction`, `TaskAction`, `Approve#workflow_command_for`, and CLI Thor verbs all delegate. Renaming `develop` → `execute` is now a one-file change.
- **`Hive::Schemas::TaskActionKind`** (`lib/hive.rb`): self-derived closed enum mirroring `NextActionKind`. Constants for every TaskAction key (READY_TO_BRAINSTORM, READY_TO_PLAN, …, AGENT_RUNNING, ARCHIVED, ERROR). Adding a new bucket without updating ALL is impossible.
- **`Hive::TaskAction` carve-outs** (`lib/hive/task_action.rb`): `:agent_working` → `agent_running` action with `command: nil` (was: misclassified as "Needs your input" with a "rerun the verb" command, sending agents into ConcurrentRunError loops). `:execute_stale` → `recover_execute` with command `findings` (was: `develop`, which would refuse on the non-terminal marker and loop). Workflow-verb commands ALWAYS include `--from <stage>` (was: only when stage_collision was true) so status-suggested commands are retry-safe by default.
- **`Hive::Commands::StageAction`** rewrite:
  - Uses `Hive::Workflows::VERBS` instead of own ACTIONS.
  - `--from` retry-after-success rescue: on `InvalidTaskPath` from stage-filtered lookup, re-resolves without `stage_filter` so a retry after a successful advance raises `WrongStage` (4) instead of "no task folder" (64). Mirrors the pattern in Approve.
  - Archive idempotency at 6-done: detects already-archived state (current_stage=6-done with :complete marker) and emits a `noop` payload instead of re-running the Done agent.
  - Single JSON envelope: passes `quiet: @json` to inner Approve and Run; rescues Hive::Error and emits a unified `hive-stage-action` envelope. No more mixed Approve-prose-then-Run-JSON output under `--json`.
- **`quiet:` kwarg on Approve and Run**: when set, the inner command does its work but emits nothing to stdout/stderr. Errors still raise typed. Used by StageAction in JSON mode.
- **`Hive::Commands::Approve#json_next_action`**: at the final stage emits `{ kind: NO_OP, reason: "final_stage" }` instead of `kind: RUN` with `hive archive <slug>` (which would loop the Done agent on retry).
- **`workflow_command_for`** in Approve: now uses `Hive::Workflows.verb_arriving_at` so the post-advance `next_action.command` and text-mode `next:` hint name the verb-to-run-at-the-new-stage (e.g. `hive plan <slug> --from 3-plan` after advancing into 3-plan), not the verb-to-advance-out. The named verb hits StageAction's at-target branch and runs the stage's agent.
- **`Hive::Commands::FindingToggle`**: the `next_action.command` and text-mode `next:` hint now include `--from <stage>` for retry idempotency.
- **`schemas/hive-stage-action.v1.json`** (new): draft 2020-12 oneOf SuccessPayload/ErrorPayload. Phase enum `promoted_and_ran` / `ran` / `noop`. Error-kind enum mirrors hive-approve plus `rollback_failed`.

**Wiki updates:**

- `wiki/modules/task_action.md` (new) — public surface, action map, marker carve-outs, command emission rules.
- `wiki/modules/workflows.md` (new) — VERBS table, reverse-lookup helpers, design rationale.
- `wiki/commands/stage_action.md` (new) — Steps Performed + JSON contract + idempotency contract for the five workflow verbs.
- `wiki/index.md` page count bumped 31 → 34.
- `lib/hive/cli.rb` `class_option :json` comment refreshed to list all eight commands that honour the flag.

**Tests:** 227 / 884 green (was 196 / 768 pre-remediation). RuboCop and Brakeman clean.

- `test/unit/task_action_test.rb` (new) — pins the 13-action matrix, the `:agent_working` and `:execute_stale` carve-outs, and `--from <stage>` inclusion on every workflow-verb command.
- `test/unit/schema_files_test.rb` — 4 new pins for `hive-stage-action`: file existence + draft, SuccessPayload required keys, ErrorPayload error_kind enum, NextAction.kind enum.
- `test/integration/run_stage_action_test.rb` — coverage for the at-target branch, promote-and-run, archive idempotency no-op, `--from` retry-after-success rescue, and unified JSON envelope on each error path.
- 5 existing tests updated for the intentional behaviour changes (--from now always emitted; final-stage emits NO_OP not RUN; archive no-op).


## 2026-04-28 — TUI robustness pass

- **`Hive::Tui::Update.apply_snapshot_arrived`**: re-clamps `model.cursor` when a poll's new snapshot makes prior coords invalid (project_idx OOB or row_idx past the project's row count); preserves cursor when still valid so benign polls don't snap selection. New tests in `test/unit/tui/update_test.rb`.
- **`Hive::Tui::App.run_charm`**: setup (`StateSource.new/start`, `BubbleModel.new`, `Bubbletea::Runner.new`, HUP hook, snapshot poller) moved INSIDE the `begin` so a constructor raise still triggers the same ensure cleanup; `ensure` block nil-guards each handle. Pre-fix, a Bubbletea::Runner failure leaked the StateSource thread.
- **`Hive::Tui::Help::ENTRIES`**: filter-mode `Esc` action renamed `:clear_filter` → `:cancel_filter` with new semantics — discards the typed buffer but preserves any committed filter (was: nuked the committed filter too).
- **`Hive::Tui::Subprocess::SUBPROCESS_LOG_MAX_BYTES`**: comment honesty pass — rotation only fires synchronously with stamp writes, so a noisy child writing tens of MB of stderr between BEGIN and END can blow past the cap; the eventual rotation moves the oversized blob to `.1`. Cap is approximate, not absolute.
