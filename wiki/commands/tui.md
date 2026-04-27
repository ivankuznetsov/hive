---
title: hive tui
type: command
source: lib/hive/tui.rb
created: 2026-04-27
updated: 2026-04-27T15:00:00Z
tags: [command, tui, observability, interactive]
---

**TLDR**: `hive tui` is the human-only, full-screen Charm bubbletea + lipgloss dashboard over `hive status`. It polls the same data source at 1 Hz, groups rows by action label, and dispatches every workflow verb as a fresh subprocess on a single keystroke. The TUI never writes markers directly, never invents pipeline behavior, and never emits JSON — agent-callable surfaces stay on `hive status` and the typed verbs (see [[commands/status]], [[commands/stage_action]]).

## Backend

The TUI's render layer is **bubbletea-ruby + lipgloss-ruby** (Charm Go libraries via FFI), wired through an MVU loop in `Hive::Tui::App.run_charm`. Frames are rendered by pure functions in `Hive::Tui::Views::*` over the frozen `Hive::Tui::Model`; state transitions flow through `Hive::Tui::Update.apply`; keystrokes are translated by `Hive::Tui::KeyMap.message_for` into typed `Hive::Tui::Messages::*` values.

The legacy curses backend remains accessible for one release as `HIVE_TUI_BACKEND=curses hive tui` in case a charm-specific terminal regression hits a user. The next release (after U11 of plan #003) deletes the curses path entirely. Both backends consume the same `StateSource` snapshot and produce the same set of keystroke→action mappings — switching backends does not change behavior, only rendering.

## Modes

| Mode | Entered by | Exited by |
|------|-----------|-----------|
| Status grid (default) | boot | `q` |
| Findings triage | `Enter` on a `review_findings` row | `Esc` |
| Agent log tail | `Enter` on an `agent_running` row | `q` / `Esc` |
| Filter prompt | `/` | `Esc` (clears) / `Enter` (commits) |
| Help overlay | `?` | any key |

## Keybindings (default mode)

| Key | Action |
|-----|--------|
| `j` / `↓` | cursor down |
| `k` / `↑` | cursor up |
| `b` | run `hive brainstorm <slug>` on the highlighted row |
| `p` | run `hive plan` |
| `d` | run `hive develop` |
| `r` | run `hive review` |
| `P` | run `hive pr` (capital so it doesn't collide with `plan`) |
| `a` | run `hive archive` |
| `Enter` | open the row's contextual mode (triage / log tail / `$EDITOR`) or dispatch the suggested command |
| `/` | open filter prompt |
| `1`–`9` | scope to the Nth registered project |
| `0` | clear project scope |
| `?` | help overlay |
| `q` | quit (default mode) |
| `Esc` | back to default mode (any sub-mode) |

In findings-triage mode `a` and `r` rebind to *bulk accept* and *bulk reject* (against `hive accept-finding --all` / `hive reject-finding --all`). The help overlay groups bindings by mode for the disambiguation.

## Verb refusal on agent_running rows

Pressing a verb key on an `action_key == "agent_running"` row whose `claude_pid_alive` is true flashes a one-line hint instead of dispatching — the verb would acquire-then-fail the per-task lock with `ConcurrentRunError` (exit 75). Pressing `Enter` on the same row opens the live log tail.

If `claude_pid_alive == false` the marker is provably stale; the verb dispatches normally so `Hive::Lock` can reap it on the next run, and the user does not have to bail out to `hive markers clear`.

## Data source

`Hive::Tui::StateSource` calls `Hive::Commands::Status#json_payload(Hive::Config.registered_projects)` in-process at 1 Hz from a non-daemon background thread. Read-only, no locks taken. The render thread reads `@current` once per frame; under MRI 3.4's GVL the pointer-sized reference write is atomic. JRuby/TruffleRuby would need a `Mutex`/`AtomicReference` upgrade — a `RUBY_ENGINE != "ruby"` boot guard makes the assumption auditable.

Snapshots carry a `current_seen_at` timestamp; if the last successful refresh is older than 5s, the header renders a `[stalled: Xs]` banner and the `@last_error` message is surfaced in the status line. The previous snapshot stays visible — the loop never crashes on a transient JSON / IO error.

## Subprocess takeover

Workflow verbs and triage's `d` (develop) keystroke dispatch via `Hive::Tui::Subprocess.takeover_command(argv, dispatch:)` on the charm path. The returned `Bubbletea::ExecCommand` runs synchronously in the framework's suspend window (raw mode disabled, cursor shown, input reader stopped). Inside the callable:

1. `Process.spawn(*argv, pgroup: true)` with stdin/stdout/stderr inherited.
2. `Process.wait2` blocks; INT/TERM forward to the child's pgroup.
3. The exit code is dispatched as `Messages::SubprocessExited(verb:, exit_code:)` via the closure-captured `dispatch` lambda (which `App.run_charm` wires to `runner.method(:send)`).
4. The framework re-enters raw mode, hides the cursor, and resumes the input reader.

The legacy curses path retains `Subprocess.takeover!(argv)` with the matching `def_prog_mode`/`endwin`/`reset_prog_mode` dance for as long as `HIVE_TUI_BACKEND=curses` is supported.

Per-`Space` finding toggles use `Hive::Tui::Subprocess.run_quiet!(argv)` instead — `Open3.capture3` runs `hive accept-finding` / `hive reject-finding` without tearing down the alt-screen, so the screen does not flash on every toggle. On a non-zero exit the captured stderr appears in the status line.

## Terminal hostility

- **Resize:** Bubble Tea's runner installs its own SIGWINCH handler and synthesises a `WindowSizeMessage`; `BubbleModel#update` translates it into `Messages::WindowSized` so views can read `model.cols`/`model.rows` without poking the framework. The legacy curses path uses ncurses' injected `KEY_RESIZE`.
- **Ctrl+Z / SIGTSTP:** Bubble Tea owns suspend/resume of the alt-screen and raw-mode toggling. The legacy curses path delegates to ncurses' default handler.
- **SIGHUP:** trapped at boot in `App.run_charm`; the trap calls `runner.send(Messages::TERMINATE_REQUESTED)`, which the runner picks up at the top of the next loop tick. Update returns `Bubbletea.quit` so the runner exits cleanly. Cleanup runs in `App.run_charm`'s `ensure` (kill the polling thread, stop StateSource, restore the previous HUP handler, `SubprocessRegistry.kill_inflight!`).
- **`at_exit`:** `SubprocessRegistry.kill_inflight!` is registered alongside the StateSource boot so a crash during init still kills any in-flight workflow-verb subprocess.
- **`--json`:** rejected at the command boundary with EX_USAGE (64); the TUI is human-only by design. The reject path emits a structured error envelope on stdout (`{"ok":false, "error_class":"InvalidTaskPath", "error_kind":"unsupported_flag", "exit_code":64, "message":...}`) so JSON consumers see typed error data without a `SCHEMA_VERSIONS` bump (the envelope intentionally omits `schema` because `hive tui` has no registered `hive-*` schema).
- **Non-tty boundary:** running `hive tui` with `$stdout` not a tty (e.g., a piped CI invocation) raises `Hive::InvalidTaskPath` and exits 64 (EX_USAGE) — same code as `--json` rejection, so wrappers branch on a single "this is a misuse, not a software fault" surface.

## Test surface

- `test/integration/tui_command_test.rb` — Thor help-text registration, `--json` rejection, non-tty boundary check.
- `test/unit/tui/*_test.rb` — pure-Ruby state machines (`StateSource`, `Snapshot`, `KeyMap`, `GridState`, `TriageState`, `LogTail::FileResolver`, `Help`, `Model`, `Messages`, `Update`, `BubbleModel`).
- `test/unit/tui/views/*_test.rb` — pure-function view tests for every Lipgloss-rendered frame (`Grid`, `Triage`, `LogTail`, `HelpOverlay`, `FilterPrompt`). Layout/text content is pinned; visual styling (color/bold/reverse) is validated by manual dogfood — lipgloss-ruby v0.2.2 strips ANSI in non-tty test environments (gap tracked in `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md`).
- `test/integration/tui_subprocess_test.rb` — `Subprocess.takeover!` / `takeover_command` / `run_quiet!` against a fake child binary.
- `test/integration/tui_smoke_test.rb` + `test/integration/tui_smoke_charm_test.rb` — PTY-based boot smokes: `bin/hive tui` paints, the seeded project name appears, `q` exits 0. The latter pins `HIVE_TUI_BACKEND=charm` explicitly so the charm path stays covered after U11 deletes curses.

No render-layer snapshot tests beyond layout pinning; mainstream Ruby tooling does not provide cell-perfect terminal-snapshot diffing.

## Backlinks

- [[cli]] · [[commands/status]] · [[commands/findings]] · [[commands/stage_action]]
- [[modules/task_action]] · [[modules/workflows]] · [[modules/findings]]
