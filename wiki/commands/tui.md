---
title: hive tui
type: command
source: lib/hive/tui.rb
created: 2026-04-27
updated: 2026-05-04T19:10:44Z
tags: [command, tui, observability, interactive]
---

**TLDR**: `hive tui` is the human-only, two-pane Charm bubbletea + lipgloss dashboard over `hive status`. v2 (2026-05-01) renders a left pane listing registered projects (with `★ All projects` virtual entry on top) and a right pane showing the scoped tasks as a 5-column compact table — icon · slug · stage · status · age. It polls the same data source at 1 Hz and dispatches every workflow verb as a fresh subprocess on a single keystroke. The TUI never writes markers directly, never invents pipeline behavior, and never emits JSON — agent-callable surfaces stay on `hive status` and the typed verbs (see [[commands/status]], [[commands/stage_action]]).

## Backend

The TUI's render layer is **bubbletea-ruby + lipgloss-ruby** (Charm Go libraries via FFI), wired through an MVU loop in `Hive::Tui::App.run_charm`. Frames are rendered by pure functions in `Hive::Tui::Views::*` over the frozen `Hive::Tui::Model`; state transitions flow through `Hive::Tui::Update.apply`; keystrokes are translated by `Hive::Tui::KeyMap.message_for` into typed `Hive::Tui::Messages::*` values.

The legacy curses backend was removed in plan #003 U11. `HIVE_TUI_BACKEND=curses hive tui` now raises a typed `Hive::InvalidTaskPath` pointing at the removal — there is no silent fallback.

## Layout

```
┌─ Header: hive tui · scope=★ All projects · filter=- · generated_at=…  ──┐
├─────────────────┬────────────────────────────────────────────────────────┤
│  ProjectsPane   │  TasksPane                                             │
│  (left, 18-28)  │  (right, cols - left)                                  │
│                 │                                                        │
│  ★ All projects │  ▶  fix-cache-…   2-brainstorm  Ready to plan      2h │
│  hive           │  🤖 metrics-…     4-execute     Agent running       1m │
│  seyarabata     │  ⚠  oauth-…       5-review      Review findings     1h │
│  appcrawl       │                                                        │
├─────────────────┴────────────────────────────────────────────────────────┤
│ Footer: [Tab] switch  [Enter] next  [n] new  [/] filter  [?] help  [q]  │
└──────────────────────────────────────────────────────────────────────────┘
```

Pane focus is keyboard-only; the focused pane border is bright cyan, the inactive pane border is faint. Below 70 cols the project pane is suppressed and the tasks pane occupies the full width — narrow terminals still get a usable view, just without the left-pane drill-down.

## Modes

| Mode | Entered by | Exited by |
|------|-----------|-----------|
| Two-pane dashboard (default) | boot | `q` |
| Findings triage | `Enter` on a `review_findings` row | `Esc` |
| Agent log tail | `Enter` on an `agent_running` row | `q` / `Esc` |
| Filter prompt | `/` | `Esc` (cancels typed buffer; any committed filter is preserved) / `Enter` (commits) |
| New idea prompt | `n` | `Esc` (cancels) / `Enter` (submits `hive new <project> "<title>"`) |
| Help overlay | `?` | any key |

## Keybindings (default mode)

| Key | Action |
|-----|--------|
| `Tab` / `Shift+Tab` | toggle pane focus (left ↔ right) |
| `h` | jump focus to the projects pane |
| `l` | jump focus to the tasks pane |
| `j` / `↓` | within the focused pane: next project (left) or next task row (right) |
| `k` / `↑` | within the focused pane: previous project (left) or previous task row (right) |
| `b` | run `hive brainstorm <slug>` on the highlighted row |
| `p` | run `hive plan` |
| `d` | run `hive develop` |
| `r` | run `hive review` |
| `P` | run `hive pr` (capital so it doesn't collide with `plan`) |
| `a` | run `hive archive` |
| `Enter` | from left pane: focus right pane. From right pane: open the row's contextual mode (triage on `review_findings`, log tail on `agent_running` / `error`) or dispatch the suggested command |
| `n` | open the new-idea prompt; submitting runs `hive new <project> "<title>"` against the project selected in the left pane (`★ All` falls back to the first registered project) |
| `/` | open filter prompt |
| `1`–`9` | scope the right pane to the Nth registered project (mirrors selection in the left pane) |
| `0` | scope back to `★ All projects` |
| `?` | help overlay |
| `q` | quit (default mode) |
| `Esc` | back to default mode (any sub-mode) |

In findings-triage mode `a` and `r` rebind to *bulk accept* and *bulk reject* (against `hive accept-finding --all` / `hive reject-finding --all`). The help overlay groups bindings by mode for the disambiguation.

## New Idea Prompt Editing

The `n` prompt is a cursor-aware single-line title editor. Printable typing inserts at the cursor; `←` / `→` move within the title; `Home` / `End` and `Ctrl+A` / `Ctrl+E` jump to the start/end; `Backspace` deletes before the cursor; `Delete` deletes under the cursor. Paste is accepted as either ordinary terminal text chunks or bracketed paste; CR/LF/TAB in pasted payloads are normalized to spaces because `hive new` takes a single title. The prompt keeps a conservative 4 KiB title buffer cap and flashes `title too long` instead of accepting oversized clipboard dumps.

Copy is still terminal/OS-owned. Hive does not implement an in-app clipboard and does not bind copy shortcuts; it only consumes bytes the terminal sends as paste input.

## Visual style

v2 anchors on a Charm-modern palette with rounded borders and semantic color:

| Action class | Color | Icon |
|---|---|---|
| `agent_running` | magenta | 🤖 |
| `error` / `recover_*` | red | ⚠ |
| `needs_input` / `review_findings` | yellow | ⏸ |
| `ready_*` | blue | ▶ |
| `archived` | green | ✓ |

Cursor highlight is reverse-video (works on monochrome terminals). Lipgloss strips ANSI when stdout isn't a tty, so the ANSI escapes don't leak into pipelines or test snapshots.

## Verb refusal on agent_running rows

Pressing a verb key on an `action_key == "agent_running"` row whose `claude_pid_alive` is true flashes a one-line hint instead of dispatching — the verb would acquire-then-fail the per-task lock with `ConcurrentRunError` (exit 75). Pressing `Enter` on the same row opens the live log tail.

If `claude_pid_alive == false` the marker is provably stale; the verb dispatches normally so `Hive::Lock` can reap it on the next run, and the user does not have to bail out to `hive markers clear`.

## Data source

`Hive::Tui::StateSource` calls `Hive::Commands::Status#json_payload(Hive::Config.registered_projects)` in-process at 1 Hz from a non-daemon background thread. Read-only, no locks taken. The render thread reads `@current` once per frame; under MRI 3.4's GVL the pointer-sized reference write is atomic. JRuby/TruffleRuby would need a `Mutex`/`AtomicReference` upgrade — a `RUBY_ENGINE != "ruby"` boot guard makes the assumption auditable.

Snapshots carry a `current_seen_at` timestamp; if the last successful refresh is older than 5s, the header renders a `[stalled: Xs]` banner and the `@last_error` message is surfaced in the status line. The previous snapshot stays visible — the loop never crashes on a transient JSON / IO error.

`Update.apply_snapshot_arrived` reclamps `model.cursor` against the new snapshot's visible rows: a poll that drops the cursor's row (e.g. the last task in a project finishes and disappears, or the project list shrinks past `project_idx`) jumps the cursor to the first visible row instead of leaving it pointing at a hidden one — without this, downstream `apply_cursor_*` handlers refuse to move from invalid coords and j/k silently noop. Still-valid cursors are preserved across benign polls so the user's selection does not snap to the top each second.

## Subprocess dispatch

Workflow verbs default to background dispatch: `Hive::Tui::Subprocess.dispatch_background(argv, dispatch:)` `Process.spawn`s the child detached into its own pgroup with stdout/stderr captured to a per-spawn file (see below), returns immediately, and a reaper Thread waits for the child and dispatches `Messages::SubprocessExited(verb:, exit_code:)` so the TUI flashes the result. The renderer keeps painting and multiple agents across multiple projects run concurrently. `Hive::Workflows::VERBS` carries an optional `interactive: true` flag for verbs that need the user's tty (stdin prompts); none of the v1 verbs are flagged interactive, so every workflow keystroke takes the background path today.

Interactive-flagged verbs would route through `Hive::Tui::Subprocess.takeover_command(argv, dispatch:)`, which returns a `Bubbletea::SequenceCommand` of three steps: exit alt-screen, run a callable synchronously inside the framework's suspend window (raw mode disabled, cursor shown, input reader stopped), then re-enter alt-screen. The callable spawns the child with stdio inherited, blocks on `Process.wait2`, and dispatches `Messages::SubprocessExited(verb:, exit_code:)` so the user sees the same flash. Used only for verbs that genuinely need the tty.

Per-`Space` finding toggles use `Hive::Tui::Subprocess.run_quiet!(argv)` instead — a bounded captured-stdio child runs `hive accept-finding` / `hive reject-finding` without tearing down the alt-screen, so the screen does not flash on every toggle. On a non-zero exit the captured stderr appears in the status line; a hung helper is terminated as a process group and reported as exit 124.

`SUBPROCESS_LOG_PATH` (`$TMPDIR/hive-tui-subprocess.log`, or `$HIVE_TUI_LOG_DIR/hive-tui-subprocess.log` when the e2e harness scopes a run) is a marker-only log: BEGIN[id] / END[id] / ERRNO records, no child stdio. Each background spawn captures its own stdout/stderr to `hive-tui-spawn-<id>.log` in the same directory (the same 8-char hex ID embedded in the marker line). The reaper deletes the per-spawn capture on `exit_code == 0` (success has nothing to diagnose) and keeps a truncated failure capture on non-zero exits so `Subprocess.diagnose_recent_failure(verb)` can read the actual stderr. `SUBPROCESS_LOG_MAX_BYTES` (10 MiB) is checked at each stamp write — when exceeded the file is renamed to `…log.1` (single rotation tier). With child output redirected away from the shared file, that cap is now an actual disk-usage bound rather than the approximate ceiling it used to be. Per-spawn captures are reaped opportunistically: every BEGIN sweeps `hive-tui-spawn-*.log` in the active log directory and deletes anything older than 24 h so a crashed reaper or a `kill -9 hive` can't leak files.

## Terminal hostility

- **Resize:** Bubble Tea's runner installs its own SIGWINCH handler and synthesises a `WindowSizeMessage`; `BubbleModel#update` translates it into `Messages::WindowSized` so views can read `model.cols`/`model.rows` without poking the framework.
- **Ctrl+Z / SIGTSTP:** Bubble Tea owns suspend/resume of the alt-screen and raw-mode toggling.
- **SIGHUP:** trapped at boot in `App.run_charm`; the trap calls `runner.send(Messages::TERMINATE_REQUESTED)`, which the runner picks up at the top of the next loop tick. Update returns `Bubbletea.quit` so the runner exits cleanly. Cleanup runs in `App.run_charm`'s `ensure` (kill the polling thread, stop StateSource, restore the previous HUP handler, `SubprocessRegistry.kill_inflight!`, reap inflight auto-heal threads). All setup (StateSource boot, `Bubbletea::Runner` construction, HUP trap install, poller spawn) is performed *inside* the same `begin` so a constructor failure still hits the same nil-guarded cleanup path — the StateSource thread can no longer leak when `Bubbletea::Runner.new` raises.
- **Crash-time cleanup:** there is no `at_exit` hook. Workflow-verb children are spawned with `pgroup: true` and intentionally **detached** — `dispatch_background` never registers them with `SubprocessRegistry`, and the registry's `kill_inflight!` is called only from `App.run_charm`'s normal-exit `ensure` block (not from `at_exit`). A signal that bypasses that ensure (`SIGKILL` of the TUI, kernel OOM kill, etc.) leaves the children running. That is the design — long-running background agents outlive an interrupted dashboard so the user can re-attach with `hive tui` and pick up the in-flight rows. Recovery for kill-class markers landing on a re-launched TUI happens via `auto_heal_kill_class_errors`, not via at-exit cleanup.
- **`--json`:** rejected at the command boundary with EX_USAGE (64); the TUI is human-only by design. The reject path emits a structured error envelope on stdout (`{"ok":false, "error_class":"InvalidTaskPath", "error_kind":"invalid_task_path", "exit_code":64, "message":...}`) so JSON consumers see typed error data without a `SCHEMA_VERSIONS` bump (the envelope intentionally omits `schema` because `hive tui` has no registered `hive-*` schema, and `error_kind` matches the value other `InvalidTaskPath` emit sites already use).
- **Non-tty boundary:** running `hive tui` with `$stdout` not a tty (e.g., a piped CI invocation) raises `Hive::InvalidTaskPath` and exits 64 (EX_USAGE) — same code as `--json` rejection, so wrappers branch on a single "this is a misuse, not a software fault" surface.

## Test surface

- `test/integration/tui_command_test.rb` — Thor help-text registration, `--json` rejection, non-tty boundary check.
- `test/unit/tui/*_test.rb` — pure-Ruby state machines (`StateSource`, `Snapshot`, `KeyMap`, `GridState`, `TriageState`, `LogTail::FileResolver`, `Help`, `Model`, `Messages`, `Update`, `BubbleModel`).
- `test/unit/tui/views/*_test.rb` — pure-function view tests for every Lipgloss-rendered frame (`ProjectsPane`, `TasksPane`, `Triage`, `LogTail`, `HelpOverlay`, `FilterPrompt`, `NewIdeaPrompt`). Layout/text content is pinned; visual styling (color/bold/reverse) is validated by manual dogfood — lipgloss-ruby v0.2.2 strips ANSI in non-tty test environments (gap tracked in `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md`). Selection / cursor highlight predicates (`ProjectsPane#selected?`, `TasksPane#highlight?`) are exposed for unit-test assertion since the rendered output cannot distinguish them in non-tty.
- `test/integration/tui_subprocess_test.rb` — `Subprocess.takeover_command` / `run_quiet!` against a fake child binary.
- `test/integration/tui_smoke_test.rb` + `test/integration/tui_smoke_charm_test.rb` — PTY-based boot smokes: `bin/hive tui` paints, the seeded project name appears, `q` exits 0.

No render-layer snapshot tests beyond layout pinning; mainstream Ruby tooling does not provide cell-perfect terminal-snapshot diffing.

## Backlinks

- [[cli]] · [[commands/status]] · [[commands/findings]] · [[commands/stage_action]]
- [[modules/task_action]] · [[modules/workflows]] · [[modules/findings]]
