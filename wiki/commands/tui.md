---
title: hive tui
type: command
source: lib/hive/tui.rb
created: 2026-04-27
updated: 2026-04-27
tags: [command, tui, observability, interactive]
---

**TLDR**: `hive tui` is the human-only, full-screen curses dashboard over `hive status`. It polls the same data source at 1 Hz, groups rows by action label, and dispatches every workflow verb as a fresh subprocess on a single keystroke. The TUI never writes markers directly, never invents pipeline behavior, and never emits JSON — agent-callable surfaces stay on `hive status` and the typed verbs (see [[commands/status]], [[commands/stage_action]]).

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

Workflow verbs and `Enter`-on-`review_findings`'s `d` (develop) keystroke dispatch via `Hive::Tui::Subprocess.takeover!(argv)`:

1. `Curses.def_prog_mode` saves the curses tty state.
2. `Curses.endwin` restores cooked-mode shell tty so the child inherits a clean terminal.
3. `Process.spawn(*argv, pgroup: true)` with stdin/stdout/stderr inherited.
4. `Process.wait2` blocks; INT/TERM forward to the child's pgroup.
5. `Curses.reset_prog_mode` + `Curses.refresh` restores the alternate screen.

Per-`Space` finding toggles use `Hive::Tui::Subprocess.run_quiet!(argv)` instead — `Open3.capture3` runs `hive accept-finding` / `hive reject-finding` without tearing down curses, so the screen does not flash on every toggle. On a non-zero exit the captured stderr appears in the status line.

## Terminal hostility

- **Resize:** ncurses' default SIGWINCH handler injects `Curses::KEY_RESIZE` into the next `getch`; the TUI redraws on receipt. No Ruby `Signal.trap("WINCH")` (per [ruby/curses#9](https://github.com/ruby/curses/issues/9)).
- **Ctrl+Z / SIGTSTP:** ncurses' default handler suspends the curses runtime; resume restores the alternate screen.
- **SIGHUP:** trapped at boot; flips a `terminate_requested` flag the render loop polls between frames. On the next iteration cleanup runs (kill any in-flight subprocess pgroup, `Curses.close_screen`, join the polling thread).
- **`at_exit`:** `Curses.close_screen` + `SubprocessRegistry.kill_inflight!` registered BEFORE the first `Curses.init_screen` so a crash during init still restores the terminal.
- **`--json`:** rejected at the command boundary with EX_USAGE (64); the TUI is human-only by design.

## Test surface

- `test/integration/tui_command_test.rb` — Thor help-text registration, `--json` rejection, non-tty boundary check.
- `test/unit/tui/*_test.rb` — pure-Ruby state machines (`StateSource`, `Snapshot`, `KeyMap`, `GridState`, `TriageState`, `LogTail::FileResolver`, `Help`).
- `test/integration/tui_subprocess_test.rb` — `Subprocess.takeover!` / `run_quiet!` against a fake child binary.
- `test/smoke/tui_smoke_test.rb` — PTY-based boot smoke: `bin/hive tui` paints, the seeded project name appears, `q` exits 0.

No render-layer snapshot tests; mainstream Ruby tooling does not provide cell-perfect terminal-snapshot diffing. The data path is unit-tested; the smoke test pins the curses round-trip end-to-end.

## Backlinks

- [[cli]] · [[commands/status]] · [[commands/findings]] · [[commands/stage_action]]
- [[modules/task_action]] · [[modules/workflows]] · [[modules/findings]]
