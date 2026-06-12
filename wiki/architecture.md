---
title: Architecture
type: architecture
source: lib/hive/, bin/hive, templates/
created: 2026-04-25
updated: 2026-06-12
tags: [architecture, overview]
---

**TLDR**: Hive is a Ruby 3.4 / Thor control plane over a nine-stage filesystem state machine. The CLI dispatches into per-stage runners; stage agents run through configured AgentProfile CLIs inside per-task and per-project locks. Optional long-running surfaces sit beside the CLI: `hive daemon` advances safe tasks automatically, `hive tui` renders a terminal dashboard, and `hive bot` turns human-input gates into Telegram interactions. Workflow state has no application database; durable task/project state is the filesystem plus global YAML config, while token-usage metrics use a small SQLite store.

## Layer cake

```
bin/hive                          Thor entry; rescues Hive::Error -> exit
  └─ lib/hive/cli.rb              command class (init / new / run / status / daemon / bot / tui)
       └─ lib/hive/commands/      Init · New · Run · Status · StageAction · Daemon · Bot · TUI helpers
            └─ lib/hive/stages/   Inbox · Brainstorm · Plan · Execute · OpenPr · Review · Artifacts · Finalize · Done
                 ├─ Stages::Base      template render + AgentProfile spawn helpers
                 ├─ ClaudeLauncher    project-global tmux/headless Claude routing
                 └─ Hive::Agent       headless subprocess wrapper
                      └─ Hive::Markers / Lock / Worktree / GitOps / Config / Task
```

Top-down, each layer only depends on the ones below it. There are no cycles. Stage runners are module-level functions (`run!`) with no shared mutable state.

## Two filesystem trees per project

1. **`<project>/.hive-state/`** — a worktree of the orphan branch `hive/state`. Holds task folders, configs, locks, logs. Never appears in master because master's `.gitignore` excludes it.
2. **`<worktree_root>/<slug>/`** (default `~/Dev/<project>.worktrees/<slug>/`) — the feature worktree. Contains actual code, branched off `<default_branch>`. Created by `4-execute/`.

Master is never modified by Hive (apart from one initial `chore: ignore .hive-state worktree` commit). All hive metadata lives on `hive/state` so master `git log` stays code-only.

## Process model

`hive run` is synchronous, single-process, single-task:

1. Parent acquires per-task lock (`<task>/.lock`, EXCL with stale-PID detection).
2. Marker-owned spawns write `AGENT_WORKING`; reviewer-style sub-spawns leave the orchestrator's marker in place.
3. Parent spawns the resolved `AgentProfile` command via `Process.spawn(..., pgroup: true, out:/err: pipe)`.
4. Parent traps SIGINT/SIGTERM to forward `kill -TERM -<pgid>` to the child group.
5. Parent's reader thread streams stdout/stderr into `<.hive-state>/logs/<slug>/<label>-<ts>.log` and keeps a bounded `final_message` tail.
6. Parent polls `Process.wait(pid, WNOHANG)` until completion or timeout. On timeout, sends TERM, waits 3s grace, escalates to KILL.
7. Exit handling first checks `Hive::AgentLimit` for provider account/rate/quota exhaustion in failed or timed-out output; marker-owned spawns become `ERROR reason=limits_reached` before generic timeout/exit-code markers.
8. The selected status-detection mode derives the result from the state-file marker, exit code, or expected-output file; runner returns `{commit:, status:}`.
9. Parent acquires per-project commit lock (`<.hive-state>/.commit-lock` flock) and runs `git add . && git commit` in the hive-state worktree.
10. Parent prints the marker + a `next:` hint and releases the task lock.

Concurrency: any number of `hive run` processes on **different** tasks can proceed in parallel; the per-project commit lock serialises only the brief `git commit` window.

## Stage-runner dispatch

`Commands::Run#pick_runner` (`lib/hive/commands/run.rb:27`) is a `case` on `task.stage_name`:

| Stage | Runner | Calls claude? | Touches code? |
|-------|--------|---------------|----------------|
| `inbox` | `Stages::Inbox` | no | no |
| `brainstorm` | `Stages::Brainstorm` | yes | no |
| `plan` | `Stages::Plan` | yes | no |
| `execute` | `Stages::Execute` | yes (impl-only since ADR-014) | yes (in feature worktree) |
| `open-pr` | `Stages::OpenPr` | yes | no code edits (`git push`, `gh pr create --draft`) |
| `review` | `Stages::Review` (orchestrator) → `Review::{CiFix,Triage,BrowserTest,FixGuardrail}` + `Hive::Reviewers` adapters | yes (CI-fix + reviewers + triage + fix + browser; sub-spawns use `status_mode: :exit_code_only` per ADR-021) | yes (fix agent commits in feature worktree) |
| `artifacts` | `Stages::Artifacts` | yes | no code edits (`artifact.md` collection handoff) |
| `finalize` | `Stages::Finalize` | yes | no code edits (`gh pr edit`, `gh pr ready`, `summary.md`) |
| `done` | `Stages::Done` | no | no |

Inbox/Done are the two non-working stages: capture-only and archive-only.

## Agent invocation contract

Headless agent spawns are profile-driven. `Hive::Agent#build_cmd`
starts with the selected `AgentProfile` binary/headless flag, then adds
profile-specific permission, add-dir, budget, per-run CLI extras, and
output-format flags. Claude, Codex, and Pi therefore share one subprocess
wrapper while keeping their CLI-specific argv and status-detection
contracts in `lib/hive/agent_profiles/`.

Claude-backed stages add one config-specific layer on top of the profile:
`Hive::Config.claude_cli_flags(cfg)` turns `claude.model` and
`claude.effort` into an argv fragment used by both headless
`Hive::Agent` and tmux `Hive::ClaudeLauncher` sessions. Fresh projects
default `claude.model` to `default`, so Hive passes Claude Code's live
recommended-model alias instead of inheriting the operator's interactive
selection. `model: inherit` (or blank) omits `--model`; aliases/full
model names pass through. `effort: default`, `inherit`, or blank omits
`--effort`; other explicit values pass through, with fresh init offering
`low`, `medium`, and `high`.

Fresh project setup separates reviewer policy by source. Normal feature
PRs use `review.reviewers`, populated by `hive init` from the normal
reviewer prompt. Synthetic patrol PR tasks whose `task.md` frontmatter
has `source: patrol` use `patrol.review.reviewers` instead; the fresh
default is the native single-pass `codex-native-review`
(`kind: codex_review`) adapter. `hive init` can add the Codex or Claude
CE `ce-code-review` fan-out reviewers for broader patrol review coverage;
`pr-review-toolkit` remains a normal-reviewer option only. The review runner
selects between those lists at Phase 2, before dispatching reviewer adapters.

For the built-in Claude profile, the default headless argv is:

```
claude -p
  --dangerously-skip-permissions
  [--add-dir <dir> ...]
  --max-budget-usd <stage_budget>
  [--model <claude.model>]
  [--effort <claude.effort>]
  --output-format stream-json
  --include-partial-messages
  --verbose
  --no-session-persistence
  <prompt>
```

`HIVE_CLAUDE_BIN` env var overrides the binary (used by tests with
`test/fixtures/fake-claude`). `--verbose` is mandatory whenever `-p` is
paired with `--output-format stream-json` (claude rejects the invocation
otherwise). When a Claude spawn receives `permission_mode` other than
`bypassPermissions`, the skip flag is replaced with
`--permission-mode <mode>`.

Claude-backed stages normally route through `Hive::ClaudeLauncher`,
which honors project config `claude.mode`. `tmux` runs an attachable
interactive Claude session using the configured
`claude.permission_mode`; `headless` delegates back to `Hive::Agent`.

Provider-limit handling is shared across headless and tmux paths through
`Hive::AgentLimit`. Headless failures inspect the captured final message
before generic timeout/exit-code handling; tmux readiness, terminal-marker,
and expected-output waits inspect the pane tail so Claude's usage-credit menu
surfaces as `limits reached for claude:` / `ERROR reason=limits_reached`
instead of being masked as a timeout or session failure.

The default Claude permission path (`bypassPermissions`, which maps to `--dangerously-skip-permissions`) is a deliberate single-developer trust model. The plan documents this trade-off explicitly: security boundaries come from (a) **per-spawn prompt-injection wrapping** with a fresh random nonce per spawn — `<user_supplied_<hex16>>…</user_supplied_<hex16>>` — so attacker-supplied closing tags can't terminate the wrapper, and a hostile reviewer output saved into `accepted_findings` can't leak into the next spawn (ADR-019 supersedes ADR-008's per-process memoization), (b) physical cwd isolation — every stage's `add-dir` is narrowed to `task.folder` (brainstorm/plan deliberately do **not** add the project root, so prompt-injected user input cannot reach project source); per-CLI variation in the isolation flag is logged to `<task>/logs/isolation-warnings.log` (ADR-018), (c) SHA-256 integrity checks on `plan.md` + `worktree.yml` (+ `task.md` for triage / fix in 6-review) around every code-touching spawn; tampering yields `<!-- ERROR reason=implementer_tampered|triage_tampered|fix_tampered -->` (ADR-013), (d) the Phase 4 auto-commit scope gate, which checks staged fallback-commit paths against `review.fix.auto_commit.scope_check` before Hive writes trailered fix commits, and (e) the post-fix diff guardrail (ADR-020 / `Hive::Stages::Review::FixGuardrail`) which scans `git diff base..head` after Phase 4 fix commits for `shell_pipe_to_interpreter`, `ci_workflow_edit`, secrets (via `Hive::SecretPatterns`), `dotenv_edit`, lockfile churn, and `100755` mode flips — match → `REVIEW_WAITING reason=fix_guardrail`. PR publishing paths (`OpenPr`, `Review::GithubPublisher`, `Finalize`) also secret-scan before sending content to GitHub.

## State machine (cross-stage)

```mermaid
stateDiagram-v2
    [*] --> S1_inbox: hive new
    S1_inbox: 1-inbox (inert)
    S1_inbox --> S2_brainstorm: user mv
    S2_brainstorm --> S2_brainstorm: hive run (next round)
    S2_brainstorm --> S3_plan: user mv (COMPLETE)
    S3_plan --> S3_plan: hive run (refine)
    S3_plan --> S4_execute: user mv (COMPLETE)
    S4_execute --> S5_open_pr: user mv (EXECUTE_COMPLETE)
    S5_open_pr --> S6_review: user mv (draft PR open)
    S6_review --> S6_review: hive run (autonomous loop: CI → reviewers → triage → fix → guardrail → browser)
    S6_review --> S7_artifacts: user mv (REVIEW_COMPLETE)
    S7_artifacts --> S8_finalize: user mv (artifact collected)
    S8_finalize --> S9_done: user mv or daemon archive after merge
    S9_done --> [*]
```

`mv` between directories is the only approval gesture. The user can always interrupt by editing files in place.

## Key external integrations

- **`claude` CLI** ≥ 2.1.118 — verified via `claude --version` at agent spawn time (`Hive::Agent.check_version!`).
- **`gh` CLI** — used by `5-open-pr`, review comment mirroring, and `8-finalize`.
- **`git`** ≥ 2.40 — uses `worktree add --no-checkout --detach`, `worktree list --porcelain`, `worktree remove`, `commit`, `show-ref`, `symbolic-ref`. All invoked through `Open3.capture3` array form (no shell).

## TUI / MVU pipeline

The TUI ([[commands/tui]]) is built on the bubbletea-ruby Model–View–Update loop, with a Hive-flavoured split that keeps state transitions pure and side effects honest.

```
bin/hive tui  →  Hive::Tui::App.run_charm
                    ├─ StateSource (1 Hz background poll)
                    │     └─ runner.send(SnapshotArrived | PollFailed)
                    └─ PasteAwareRunner < Bubbletea::Runner
                          ├─ InputDecoder.drain(raw_bytes)  → [Hive::Tui::Messages::*]
                          └─ BubbleModel#update(message)
                                ├─ translate(framework_msg → hive_msg)
                                │     └─ KeyMap.message_for(mode, key, row, pane_focus)
                                ├─ handle_side_effect(hive_msg)   ── I/O & runner-aware ──
                                │     (DispatchCommand, OpenLogTail,
                                │      OpenInputEditor, NewIdeaSubmitted, …)
                                └─ Update.apply(hive_model, msg)  ── pure state transition ──
```

### Layer responsibilities

- **`Hive::Tui::Model`** — frozen `Data` record holding the entire UI state (snapshot, scope, filter, cursor, mode, prompt buffers). Mutated only via `Model#with(...)`.
- **`Hive::Tui::Update`** (`lib/hive/tui/update.rb`) — pure dispatch on `Messages::*`. Returns `[new_model, cmd]` where `cmd` is either `nil` or a Bubbletea command (e.g., `Bubbletea.quit`). No I/O, no Bubbletea coupling — fully unit-testable without a terminal.
- **`Hive::Tui::Messages`** (`lib/hive/tui/messages.rb`) — closed enum of `Data.define` records / singleton classes, one per state-transition kind. New transitions add a Message + an `Update.apply` branch + a test.
- **`Hive::Tui::KeyMap`** (`lib/hive/tui/key_map.rb`) — pure `(mode, key, row, pane_focus) → Message`. Centralises every keystroke binding so curses/Bubbletea backends share one contract.
- **`Hive::Tui::BubbleModel`** (`lib/hive/tui/bubble_model.rb`) — `Bubbletea::Model` adapter. Translates framework messages (`KeyMessage`, `WindowSizeMessage`, `RawTextInput`) into Hive Messages, then either delegates to `Update.apply` (pure path) or runs them through `#handle_side_effect` (impure path) for messages that need a runner reference (`DispatchCommand`) or perform synchronous I/O (`OpenLogTail`, `OpenInputEditor`, `NewIdeaSubmitted`, …). I/O lives here so Update stays pure.
- **`Hive::Tui::PasteAwareRunner`** (`lib/hive/tui/paste_aware_runner.rb`) — `Bubbletea::Runner` subclass overriding `run_loop` / `process_input` to drain every raw read through `InputDecoder`. Pinned to bubbletea 0.1.4 (boot-time `VERSION` check) because the override touches private superclass instance variables.
- **`Hive::Tui::InputDecoder`** (`lib/hive/tui/input_decoder.rb`) — stateful byte-level decoder. Exists because the stock `Program#poll_event` parses one event per raw read and drops the rest of the bytes, breaking paste of more than ~16 bytes. The decoder buffers partial escape sequences across reads, brackets paste content with `\e[200~`/`\e[201~`, normalises paste content (CR/LF/TAB → space, C0/DEL stripped), caps `@pending` at 4 KiB and `@paste_buffer` at 1 MiB, and force-flushes a stalled paste after 5 seconds.
- **`Hive::Tui::Views::Format`** (`lib/hive/tui/views/format.rb`) — shared view formatting helpers. Truncation and left/right padding measure terminal display cells via `unicode-display_width`, so wide glyphs in task names or status icons do not shift fixed TUI columns.

### Key seams

- **Side-effect seam** — `BubbleModel#handle_side_effect` returns `[new_model, cmd]` to short-circuit `Update.apply`, or `nil` to fall through. This is the single line where impurity is allowed; everything else flows through `Update.apply`.
- **Paste routing-by-mode** — `InputDecoder` emits a `Messages::RawTextInput(text:, paste:)` for any text-bearing chunk; `BubbleModel#translate_raw_text_input` rewrites it to `NewIdeaTextInserted` / `FilterTextInserted` based on `model.mode`, so a paste landing in `:grid` mode never mutates a hidden prompt buffer.
- **Decoder reset on cancel** — `PasteAwareRunner` watches for transitions away from the previous editable mode (`:new_idea` / `:filter`, including `:new_idea ↔ :filter` jumps) and calls `InputDecoder#reset!` so an orphan paste held mid-prompt cannot dump into the next prompt.
- **GVL yielding** — bubbletea-ruby's input reader holds the GVL for the full `input_timeout`; `BubbleModel` schedules a recurring 10 ms `YieldTick` whose handler calls `Thread.pass`, keeping the StateSource poller and other background threads alive. See `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md`.

Cross-link: [[commands/tui]] for the user-facing surface, [[state-model]] for the snapshot grammar the TUI renders.

## Telegram bot pipeline

The Telegram bot ([[commands/bot]]) is the mobile-shaped companion to
the daemon. It watches the same `hive status --json` stream, uses the
same `Hive::TaskAction` classification, and turns rows that require
human input into inline-keyboard or free-text conversations.

```
hive bot start  →  Hive::Commands::Bot
                    └─ Hive::Bot::Supervisor
                         ├─ Telegram long-poll loop
                         │    └─ Router → slash/callback/free-text handlers
                         ├─ StatusWatcher loop
                         │    └─ NotificationDispatcher → inline keyboards
                         └─ ChildSupervisor reaper
                              └─ replies when spawned hive commands finish
```

The trust boundary matches the daemon: the bot is a thin command/draft
surface, not an alternate approval engine. Stage approvals call workflow
verbs with `--from <stage> --json`; recovery buttons call
`hive markers clear`; triage buttons call `hive accept-finding` /
`reject-finding`; text-only idea capture calls `hive new`. Two
in-process writes are intentionally scoped: brainstorm answer insertion,
which is limited to `### A<N>.` blocks under
`Hive::Lock.with_task_lock`, and Telegram idea-draft submission with
attachments or voice-note transcripts. Attachment capture downloads
allowed media into a temp staging dir; voice capture downloads the
Telegram voice file, transcribes it through `Hive::Bot::Transcriber`,
keeps only the confirmed transcript on the happy path, then calls
`Hive::Commands::New#call!` with the same body/attachment arguments as
other idea drafts. Final task files are still written through the same
`hive new` command path.

The Telegram bot answers brainstorm questions deterministically: an
operator replies in chat (or via `/answer <slug>`), the bot writes the
literal reply into the next unanswered slot of `brainstorm.md`, then
sends the next question. The earlier "Codex draft-assist" flow — where
Path A spawned Codex to draft an answer with write-draft/edit/cancel
buttons — has been retired; see [[modules/bot]] and [[state-model]].

## Dispatch flow (single-dispatcher contract, plan 2026-05-28-002)

For state-mutating workflow verbs (`run`, `develop`, `brainstorm`,
`plan`, `review`, `open-pr`, `artifacts`, `finalize`, `archive`,
`markers clear`) there is exactly ONE writer: the daemon. The bot
and any future external caller (TUI, web UI) are producers that
write file-backed JSON requests; the daemon's tick loop is the
only thing that calls `Process.spawn` on those verbs.

```
operator → /done in Telegram
   └─ Hive::Bot::Supervisor#execute_dispatch
        └─ Hive::Bot::DispatchRequestWriter.write!
             └─ <state_home>/dispatch_requests/<ts>-<id>.json
                  ↑ atomic tmp + File.rename — partial reads impossible
   ┄ wait for next daemon tick ┄
   └─ Hive::Daemon::Dispatcher#tick
        └─ Hive::Daemon::DispatchRequestQueue.pending
             └─ allowlist + expiry + per-slug in-flight gate
                  └─ Hive::Daemon::ChildSupervisor#spawn (with request_id)
                       └─ hive run ... (the real subprocess)
                            └─ reap_completed
                                 ├─ controller.observe_state_file_mtime (refresh baseline)
                                 ├─ DispatchRequestQueue.remove(request_id)
                                 └─ :dispatch_request_completed event
```

Read-only verbs (`hive status`, `hive status --diagnose`,
`hive doctor`, `gh pr view`) and verbs outside the allowlist
(`hive new`, `hive approve`, `hive accept-finding`,
`hive reject-finding`) still spawn directly from the bot via
`Hive::Bot::ChildSupervisor`. They don't bump task state-file
mtimes and don't cause the dual-writer race the queue exists to
prevent.

Why the file-backed queue beats an event bus or sockets: every
hive-state-mutating operation already touches the filesystem
under one well-known root (`Hive::Paths.state_home`), the
atomic-rename idiom is already standard in this codebase
(`Hive::Markers.write_atomic`, `DispatchBaselines#persist!`),
and the daemon's tick was already a single-threaded sequential
loop. The queue is the smallest possible addition that satisfies
the single-dispatcher invariant. See [[modules/daemon]]
§"Single-dispatcher" for the per-step gates and telemetry events.

## Code conventions

- Ruby 3.4, frozen-string-literal **disabled** (per `.rubocop.yml`).
- Double-quoted strings (`Style/StringLiterals: double_quotes`).
- Layout/LineLength max 120; Metrics/MethodLength max 30; Metrics/AbcSize max 35; Metrics/ClassLength max 200.
- Module-level functions (`module_function`) for stateless helpers (`Stages::*`, `Markers`, `Lock`, `Config`).
- Classes for stateful entities (`Task`, `Worktree`, `GitOps`, `Agent`, `CLI`, `Commands::*`).

## Related pages

- [[state-model]] — directory layout, marker grammar, configs.
- [[cli]] — command surface.
- [[dependencies]] — gem choices.
- [[decisions]] — architectural decisions (ADR style).
- [[modules/agent]] · [[modules/agent_profile]] · [[modules/worktree]] · [[modules/git_ops]] · [[modules/markers]] · [[modules/lock]] · [[modules/task]] · [[modules/config]] · [[modules/daemon]] · [[modules/bot]]
