---
title: "U2 verification — Charm bubbletea + lipgloss Ruby gems API surface"
date: 2026-04-27
status: blocking-decision
plan: docs/plans/2026-04-27-003-refactor-hive-tui-charm-bubbletea-plan.md
gem-versions:
  bubbletea: 0.1.4
  lipgloss: 0.2.2
---

# U2 — Charm Ruby gems API verification

Probed against installed gems on `ruby 3.4.7-x86_64-linux-gnu`. Probe script: `/tmp/charm_api_probe.rb`. Findings inform the decision gate before U3+.

## Bubbletea API — verified present

| Primitive | Status | Notes |
|---|---|---|
| `Bubbletea.run(model, **opts)` | ✅ Present | Discards Runner reference. Use `Bubbletea::Runner.new(model, **opts).run` to keep the reference for external `runner.send(msg)`. |
| `Bubbletea.quit` | ✅ Present | Returns `QuitCommand`. Update returns `[model, Bubbletea.quit]` to exit. |
| `Bubbletea.tick(duration) { msg }` | ✅ Present | Returns `TickCommand`. **Callback runs synchronously on the main thread** (`runner.rb#process_ticks`). Heavy work in the callback (e.g., `Hive::Commands::Status#json_payload` walking the filesystem) blocks rendering. **Use a background thread + `runner.send(msg)` for the StateSource refresh, not Tick.** |
| `Bubbletea.batch(*cmds)`, `Bubbletea.sequence(*cmds)` | ✅ Present | |
| `Bubbletea.send_message(msg, delay: 0)` | ✅ Present | Returns `SendMessage`; runner enqueues into the message stream. |
| Takeover helper (the `exec` module method) | ✅ Present | Returns `ExecCommand`. Runner runs the callable synchronously in the suspend window (raw mode disabled, cursor shown, input reader stopped), then re-enters raw mode. **Does NOT propagate child exit code through the framework.** Use closure-captured holder + `runner.send(SubprocessExited.new(exit_code:))` from inside the callable. |
| `Bubbletea.suspend` | ✅ Present | Issues SIGTSTP; ResumeMessage delivered on SIGCONT. |
| `Bubbletea.enter_alt_screen`, `Bubbletea.exit_alt_screen` | ✅ Present | Return commands toggling alt-screen at runtime. The takeover helper does NOT toggle alt-screen — if the parent runs `alt_screen: true` and the child writes outside alt-screen, output goes into the alt-screen buffer. |
| `Bubbletea::Runner#send(message)` | ✅ Present (instance-defined) | Overrides `Object#send`. Appends to `@pending_messages` array under MRI-GVL atomic semantics. Drained at top of each `run_loop` iteration. **External-thread injection works** — this is how SIGHUP traps and the StateSource background thread inject messages. |
| `Bubbletea::Model` mixin module | ✅ Present | User class includes it and implements `init` / `update(msg) → [model, cmd]` / `view → String`. |
| `Bubbletea::WindowSizeMessage` | ✅ Present | Auto-sent on terminal resize via SIGWINCH trap installed by Runner. **Note Runner installs its own SIGWINCH handler** (`runner.rb#setup_resize_handler`) — chains a previous handler if one was set, but this means the existing `Hive::Tui` SIGWINCH (which is currently nil/default) does not need to coexist. |

## Lipgloss API — partially verified, one critical gap

| Primitive | Status | Notes |
|---|---|---|
| `Lipgloss::Style.new` | ✅ Present | Builder API. |
| `Style#foreground(color)`, `#background`, `#bold`, `#reverse`, `#render` | ✅ Present | |
| `Lipgloss::ANSIColor.resolve(symbol_or_string_or_int)` | ✅ Present | Maps `:cyan → "6"`, `"212" → "212"`, `212 → "212"`. |
| `Style#foreground(:cyan)` (Symbol arg) | ❌ **TypeError** | `wrong argument type Symbol (expected String)`. The C-extension binding rejects symbols at the foreground/background call site even though `ANSIColor.resolve` accepts them. Workaround: `Style#foreground(ANSIColor.resolve(:cyan))` — wrap symbols at the call site. |
| `Style#foreground("212")`, `Style#foreground("#00ffff")` | ✅ Works | String ANSI-256 indices and hex colors are accepted. |
| `Lipgloss.join_horizontal`, `join_vertical`, `place` | ✅ Present | |
| `Lipgloss::Table`, `Lipgloss::List`, `Lipgloss::Tree`, `Lipgloss::Border` | ✅ Present | Useful for grid + triage layouts. |
| `Lipgloss.has_dark_background?`, `Lipgloss.size`, `Lipgloss.width`, `Lipgloss.height` | ✅ Present | Adaptive helpers. |
| **Force color profile when stdout is not a tty** | ❌ **NOT EXPOSED** | No `Lipgloss.set_default_renderer`, no `Lipgloss.new_renderer(profile:)`, no `FORCE_COLOR` env var honored. When stdout isn't a tty, `Style#render("text")` returns plain `"text"` with no ANSI escapes. **Verified:** even with `FORCE_COLOR=true`, `COLORTERM=truecolor`, `TERM=xterm-256color` exported, render output remained 5 bytes for 5 visible characters (no styling). |

## Critical gap: headless ANSI output for view tests

**The U2 verification reveals that plan #003's KTD-7 test layer 2 ("View golden strings") cannot validate visual styles in tests.** Lipgloss-ruby v0.2.2 does not surface the upstream Go `lipgloss.SetDefaultRenderer` / `lipgloss.NewRenderer(io.Writer)` API — the only equivalent that would force ANSI output in a non-tty test environment.

**Implication for plan #003's R19 (visual quality bar):**

R19 says: "Validated by manual dogfood + **at least three lipgloss-styled fixtures pinned in tests**". The lipgloss-styled fixtures are **not stable** in the test environment because the styling is conditionally stripped. View tests can pin:

- ✅ Layout (column positions, text content, line wrapping, truncation)
- ✅ Conditional content (cursor row visible vs hidden, flash text present vs absent)
- ❌ Foreground colors
- ❌ Background colors
- ❌ Bold / reverse / underline modifiers

Manual dogfood is required to validate visual styles. CI cannot.

## Decision gate

The plan's KTD-7 test ergonomics claim ("substantially better than ratatui") was the headline differentiator over plan #002. Without forced-color rendering in tests, the test layer collapses to layout-only — which is what `ratatui_ruby`'s `TestBackend` already provides (and arguably better, since `TestBackend` is a documented Ruby surface in the gem, not an upstream C-extension gap).

### Three paths

| Path | Description | Cost / Risk |
|---|---|---|
| **A. Continue plan #003 with the gap.** | Accept that view tests pin layout, not colors. Update R19 to "manual dogfood validates colors; layout pinned in tests". Drop the "lipgloss-styled fixtures" language. | Charm migration ships (11 units) but with weaker test guarantee than the plan claimed. The architectural-shift cost (MVU restructure, KTD-2/3) is paid for a benefit that's now equivalent to plan #002's. |
| **B. Pivot to plan #002 (ratatui_ruby).** | Abandon Charm. Use ratatui's `TestBackend` for cell-buffer asserts in tests. Smaller restructure (no MVU; immediate-mode is closer to current curses architecture). | Smaller blast radius. Ratatui_ruby has its own alpha-stage caveats but a more mature test backend. |
| **C. Open upstream + workaround.** | Submit PR to `lipgloss-ruby` exposing the renderer-profile API; in the meantime, write a Ruby wrapper that calls the C-extension's lower-level Style render with a forced profile. | Unknown timeline; extends U2 indefinitely. Marco Roth's responsiveness is the variable. Not the right move for a v1 daily-driver tool. |

### Recommended: **Path B — pivot to plan #002 (ratatui_ruby)**

Rationale:
1. **Agent-first verifiability is the user's stated decision axis.** Without forced-color rendering, Charm's test ergonomics advantage over ratatui evaporates — both produce equivalent layout-pinned tests.
2. **Plan #003's MVU restructure was justified by the test-ergonomics ceiling.** Without that ceiling, the restructure is overhead without payoff.
3. **The brainstorm's "thin overlay + small carrying cost" framing favors the lighter-touch path.** Plan #002 keeps state machines as-is (immediate-mode); plan #003 reshapes them (MVU). Lighter is closer to brainstorm intent.
4. **5/6 of the original v1 dogfood bugs are already fixed in curses** (commits `9c30097..93611c9`). Plan #002's render-layer-only swap targets the remaining bug (alt-screen handoff on Ghostty) without touching the cursor-vs-snapshot ordering / termios / pause-prompt fixes that already shipped.

A future re-evaluation of Path A becomes appropriate once `lipgloss-ruby` exposes a renderer-profile API.

## Other findings

- **Lipgloss has `Table`, `List`, `Tree` widgets** built-in (not separate `bubbles` gem dependency). Useful if Path A is reconsidered.
- **`Bubbletea::Runner#send` overrides `Object#send`** — the instance method is defined directly so `Object#send`'s invoke-arbitrary-method semantics don't fire. This is a feature, not a bug, but tooling that introspects instance_methods may flag it.
- **The bubbletea-ruby Runner installs its own SIGWINCH handler** (`runner.rb:99-117`). This conflicts with any pre-existing SIGWINCH trap; the existing `Hive::Tui` does not install one (per origin plan KTD-5), so coexistence is fine.
- **The takeover callable does NOT preserve `pgroup: true`** by itself — the implementer is responsible for `Process.spawn(*argv, pgroup: true)` inside the callable. SIGHUP cleanup via `SubprocessRegistry.kill_inflight!` continues to work because the existing pattern from `lib/hive/tui/subprocess.rb` is unchanged.
