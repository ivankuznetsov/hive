---
title: hive tui
type: command
source: lib/hive/tui.rb, lib/hive/tui/**
created: 2026-04-27
updated: 2026-06-15
tags: [command, tui, observability, interactive, diagnostics, task-id, archive, pr]
---

**TLDR**: `hive tui` is the human-only, two-pane Charm bubbletea + lipgloss dashboard over `hive status`. v2 (2026-05-01) renders a left pane listing registered projects (with `★ All projects` virtual entry on top) and a right pane showing scoped tasks as a compact table — icon · id · PR · display name · stage · status · age. It polls the same data source at 1 Hz and dispatches every workflow verb as a fresh subprocess on a single keystroke. The TUI never writes markers directly, never invents pipeline behavior, and never emits JSON — agent-callable surfaces stay on `hive status` and the typed verbs (see [[commands/status]], [[commands/stage_action]]).

## Backend

The TUI's render layer is **bubbletea-ruby + lipgloss-ruby** (Charm Go libraries via FFI), wired through an MVU loop in `Hive::Tui::App.run_charm`. Frames are rendered by pure functions in `Hive::Tui::Views::*` over the frozen `Hive::Tui::Model`; state transitions flow through `Hive::Tui::Update.apply`; keystrokes are translated by `Hive::Tui::KeyMap.message_for` into typed `Hive::Tui::Messages::*` values.

The legacy curses backend was removed in plan #003 U11. `HIVE_TUI_BACKEND=curses hive tui` now raises a typed `Hive::InvalidTaskPath` pointing at the removal — there is no silent fallback.

## Layout

```
┌─────────────────┬────────────────────────────────────────────────────────┐
│  ProjectsPane   │  TasksPane                                             │
│  (left, 18-28)  │  (right, cols - left)                                  │
│                 │                                                        │
│  ★ All projects │  ▶   42  #561  Fix cache    2-brainstorm Ready to p. 2h │
│  hive           │  🤖  43  —     Metrics pass 4-execute    Agent run.  1m │
│  myapp          │  ⚠   —  #612  oauth-…      6-review     Needs rec.  1h │
│  appcrawl       │                                                        │
├─────────────────┴────────────────────────────────────────────────────────┤
│ Footer: [Tab] ... [q] quit · today ... • 7d ... • all ... • tokens       │
└──────────────────────────────────────────────────────────────────────────┘
```

Pane focus is keyboard-only; the focused pane border is bright cyan, the inactive pane border is faint. Below 70 cols the project pane is suppressed and the tasks pane occupies the full width — narrow terminals still get a usable view, just without the left-pane drill-down.

The dashboard intentionally has no persistent metadata header. Scope and filter context live in pane titles and prompt modes, while `generated_at` remains an internal snapshot field rather than always-on chrome. The composer computes pane height from `model.rows` minus any stalled banner and footer rows; both panes clip/pad to that budget. The project and task panes use the shared `Views::Format.viewport_start` cursor-following calculation, so vertical terminal shrink keeps the selected project/task visible and keeps the footer on-screen instead of letting rows overflow below it.

## Modes

| Mode | Entered by | Exited by |
|------|-----------|-----------|
| Two-pane dashboard (default) | boot | `q` |
| Red-status detail | `Enter` on selected red recovery/error rows | `q` / `Esc` |
| Agent log tail | `Enter` on an `agent_running` row | `q` / `Esc` |
| Input editor | `Enter` on a `needs_input` row | editor exit; completed brainstorm answers auto-continue; plan rows auto-advance to `develop` (or auto-revise if user added feedback) |
| Filter prompt | `/` | `Esc` (cancels typed buffer; any committed filter is preserved) / `Enter` (commits) |
| New idea project picker | `n` from `★ All projects` scope | `Esc` / `q` (cancels) / `Enter` (selects and advances to title prompt) |
| New idea prompt | `n` (single-project scope), or after picker selection (all-projects scope) | `Esc` (cancels) / `Enter` (submits `hive new <project> "<title>"`) |
| Info panel | `i` on a selected right-pane task | `q` / `Esc` / `i` |
| Archive pane | `z` | `q` / `Esc` |
| Help overlay | `?` | `q` / `Esc` / `?` |

## Keybindings (default mode)

| Key | Action |
|-----|--------|
| `Tab` / `Shift+Tab` | toggle pane focus (left ↔ right) |
| `h` / `Left` | jump focus to the projects pane; below the two-pane breakpoint the tasks pane remains focused |
| `l` / `Right` | jump focus to the tasks pane |
| `j` / `↓` | within the focused pane: next project (left) or next task row (right) |
| `k` / `↑` | within the focused pane: previous project (left) or previous task row (right) |
| `b` | run `hive brainstorm <slug>` on the highlighted row |
| `p` | run `hive plan` |
| `d` | run `hive develop` |
| `r` | run `hive review` |
| `P` | run `hive open-pr` (capital so it doesn't collide with `plan`) |
| `F` | run `hive finalize` |
| `a` | run `hive archive` |
| `Enter` | from left pane: focus right pane. From right pane: perform the row's contextual action: input editor on `needs_input` (completed brainstorm answer rounds auto-run; plan rows auto-advance to `develop` or auto-revise on user feedback), log tail on `agent_running` (and on `error` rows still in a kill-class auto-heal window), red-status detail on selected review-recovery and non-kill-class `error` rows, direct retry/browse for the legacy review-stale exceptions, and suggested-command dispatch for ready rows |
| `o` | open the focused row's hive-state task folder in `$VISUAL` / `$EDITOR` / `vi` for read-only browsing — no marker change, no workflow dispatch. Distinct from `Enter` (workflow-contextual) and the verb keys (subprocess dispatch). Useful for revisiting investigation outputs in `9-done` (or any stage). |
| `i` | open the focused row's in-TUI info panel — no editor handoff, no marker change, no workflow dispatch. |
| `s` | steer the focused task manually: open the configured `execute.agent` in the feature worktree with every existing stage folder for that slug passed as agent context, mark the row `MANUAL_STEERING`, and archive the slug under `archived-manual/` when the agent exits |
| `z` | open the Archive pane, listing all `9-done` tasks across projects with no age cutoff |
| `n` | open the new-idea flow; if scope is `★ All projects`, first show a project picker, then submit with `hive new <project> "<title>"` against the chosen concrete project |
| `/` | open filter prompt |
| `1`–`9` | scope the right pane to the Nth registered project (mirrors selection in the left pane) |
| `0` | scope back to `★ All projects` |
| `X` | drop the focused task with `hive drop <slug> --project <project> --from <stage> --json`: kill its agent, remove task folder(s), worktree, branch, locks, logs, and any draft PR. No undo and no confirmation beyond Shift. Lowercase `x` is unbound. Registry cleanup stays in the shell via [[commands/forget]] / [[commands/prune]]. |
| `?` | help overlay |
| `q` | quit (default mode) |
| `Esc` | back to default mode (any sub-mode) |

Findings triage is no longer an in-TUI mode. Use `hive findings`, `hive accept-finding`, and `hive reject-finding` directly from a shell or coding agent; legacy `EXECUTE_WAITING findings_count` rows surface as `recover_execute` and point at `hive findings` from status JSON (see [[commands/findings]]). In red-status detail mode, `Enter` runs hive's automated recovery for the task and closes the detail screen (rows with no auto-recovery recipe surface a refusal flash that names `Open in agent` as the manual fallback before closing), `o` opens the task in the project's configured development agent and closes the detail screen, and `q` / `Esc` returns to the grid. The help overlay groups bindings by mode for the disambiguation.

The help overlay is height-bounded and scrollable. It word-wraps binding descriptions to the available width, shows a right-edge scrollbar when the full cheatsheet is taller than the viewport, and keeps its in-overlay footer visible. Use `j` / `k`, Up / Down, PgUp / PgDn, Home / End, `g` / `G`, or the mouse wheel to scroll; `q`, `Esc`, or `?` closes. Unmapped keys no-op instead of dismissing the overlay. Terminals smaller than 10 rows by 40 columns render a centered "terminal too small" fallback instead of a clipped border box.

## New Idea Prompt Editing

The `n` prompt is a cursor-aware single-line title editor. When the dashboard scope is `★ All projects`, `n` first opens a concrete project picker (`j`/`k` or arrows to move, `Enter` to choose, `Esc` to cancel) so task capture never silently lands in the first registered project; if the first status snapshot has not arrived yet, the picker stays open in a loading state until projects are available. After a project is chosen, printable typing inserts at the title cursor; `←` / `→` move within the title; `Home` / `End` and `Ctrl+A` / `Ctrl+E` jump to the start/end; `Backspace` deletes before the cursor; `Delete` deletes under the cursor. Paste is accepted as either ordinary terminal text chunks or bracketed paste; CR/LF/TAB in pasted payloads are normalized to spaces because `hive new` takes a single title. The prompt keeps a conservative 4 KiB title buffer cap and flashes `title too long` instead of accepting oversized clipboard dumps.

### Image paste

Image paste is only active in the `:new_idea` composer. On bracketed paste, BubbleModel first probes the OS clipboard for PNG bytes (`wl-paste` on Wayland, `xclip` on X11, `pbpaste` fallback), then falls back to treating the pasted text as a drag-dropped local image path (`.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`, ≤10 MiB). Ctrl+V inside the composer is also treated as an explicit clipboard probe so terminals that do not emit a bracketed-paste burst for image-only clipboards (notably Ghostty on Wayland with Hyprland screenshot tools) still stage the image; the probe pipeline, staging convention, placeholder syntax, and submit rewrite are unchanged from the bracketed-paste path. Ctrl+V outside `:new_idea` is ignored, including when the help overlay is visible.

Accepted images are staged in a per-composer temp directory and inserted into the prompt as `[imageN]`. The prompt's last visual row shows a `· [N image(s)]` badge (rendered by `Views::NewIdeaPrompt#render_rows`, NOT in the bottom-strip footer view) while attachments are staged (ASCII-only, no emoji — the prompt label width math is lipgloss-managed and emoji glyphs split unpredictably across terminals). On submit, the TUI calls `Hive::Commands::New#call!` directly: `[imageN]` tokens become `![](assets/bug-N.<ext>)`, files are copied into `1-inbox/<slug>/assets/`, and the recursive commit in [[modules/git_ops]] captures `idea.md` plus assets together.

Missing image files or unmatched placeholders block submit and keep the prompt open with `broken image placeholder: imageN`. Non-image drag-drop paths flash `drag-drop ignored (not an image)`. Clipboard/write failures flash inline and do not insert a placeholder. Drag-dropped `.jpg`/`.webp` files keep their extension (`bug-N.jpg`, not forced `.png`) so downstream Claude Code MIME inference stays correct. `1-inbox` remains inert; [[stages/inbox]] still documents the `hive run` refusal.

Copy is still terminal/OS-owned. Hive does not implement an in-app clipboard and does not bind copy shortcuts; it only consumes bytes the terminal sends as paste input.

## Visual style

v2 anchors on a Charm-modern palette with rounded borders and semantic color:

| Action class | Color | Icon |
|---|---|---|
| `agent_running` | magenta | 🤖 |
| `error` / `recover_*` | red | ⚠ |
| `needs_input` | yellow | ⏸ |
| `ready_*` | blue | ▶ |
| `archived` | green | ✓ |
| `manual_steering` | green | 🛠 |

Cursor highlight is reverse-video (works on monochrome terminals). Lipgloss strips ANSI when stdout isn't a tty, so the ANSI escapes don't leak into pipelines or test snapshots.

## Verb refusal on agent_running rows

Pressing a verb key on an `action_key == "agent_running"` row whose `claude_pid_alive` is true flashes a one-line hint instead of dispatching — the verb would acquire-then-fail the per-task lock with `ConcurrentRunError` (exit 75). Pressing `Enter` on the same row opens the live log tail.

If `claude_pid_alive == false` the marker is provably stale; the verb dispatches normally so `Hive::Lock` can reap it on the next run, and the user does not have to bail out to `hive markers clear`.

## Data source

`Hive::Tui::StateSource` polls at 1 Hz from a non-daemon background
thread. TUI boot performs one synchronous `StateSource#refresh_now` before
entering Bubbletea's render/input loop, then seeds the initial model with that
snapshot so the first useful frame shows registered projects/tasks instead of a
long-lived loading grid. This is necessary because bubbletea-ruby's raw input
poll can starve Ruby background threads during startup; relying on the first
background poll alone produced multi-second loading screens even when
`hive status` itself was fast. After boot, the source calls
`Hive::Commands::Status#json_payload(Hive::Config.registered_projects)`
in-process whenever the cached mtime
fingerprint changes; otherwise it reuses the previous `Snapshot` and
only refreshes `current_seen_at`. The fingerprint watches the global
project registry (`Hive::Config.global_config_path`), each visible
row's state file and `.lock`, plus the project's `.hive-state/stages`
directory and stage children, so ordinary marker edits, newly-created
task folders, runner lock acquisition/release, and `hive init`/`forget`
registry changes all invalidate the cache without reparsing unchanged
status data. A time-bounded fallback
(`LIVENESS_REPARSE_FALLBACK_SECONDS`, 3s) forces a full re-parse even
when the fingerprint is unchanged, so liveness-derived fields
(`live_task_lock`, `claude_pid_alive`) that flip without touching any
file cannot stay stale indefinitely. This makes the "near-zero idle
CPU" AC a partial win: even with unchanged mtimes the fallback re-incurs
a full `json_payload` + `Dir.glob` fingerprint rebuild ~20×/min (every
3s). It is an accepted correctness tradeoff — those liveness fields flip
without any file write and must self-heal — and it never causes a redraw
because `App.start_snapshot_poller` dedups identical snapshots (below).
Because status is the sole task-row producer, stage-move races are
normalised upstream: `Status#collect_rows` skips task folders that vanish
mid-read, re-raises `ENOENT` when the folder still exists, and prunes
duplicate-slug rows only when one duplicate folder has already disappeared by
the end of the scan. The TUI therefore should not render a one-poll
old-stage/new-stage duplicate during ordinary forward workflow moves; a
backward move to an already-scanned stage can drop out for one poll and then
reappear on the next refresh. Two still-existing same-slug folders remain
visible as a real status collision.
Read-only, no locks taken. The render thread reads `@current` once per frame; under
MRI 3.4's GVL the pointer-sized reference write is atomic.
JRuby/TruffleRuby would need a `Mutex`/`AtomicReference` upgrade — a
`RUBY_ENGINE != "ruby"` boot guard makes the assumption auditable.

`Hive::Tui::App.start_snapshot_poller` wakes every 0.5s and dispatches a
`SnapshotArrived` message only when `state_source.current` differs from
the last dispatched snapshot. Identical snapshots do not redraw.

`Hive::Tui::Snapshot::Row` carries `slug`, `id`, `display_name`, `pr_url`, `mtime`, and `folder_mtime` from status JSON. The task list hides the slug in favor of the id/name columns, using the slug as the name fallback when display generation has not succeeded or a legacy task has not been backfilled. Detail views keep the slug visible beside `#id display_name`. Filtering still matches the slug and now also matches display name and stringified id.

The task grid has a fixed PR column between id and display name. Rows with no parseable pull-request URL render `—`; rows whose `pr_url` ends in `/pull/<number>` render `#<number>` via [[modules/pr]]. When stdout is a TTY, the number is wrapped in an OSC 8 hyperlink by `Hive::Tui::Views::Hyperlink`; invalid or non-http URLs fall back to the plain label. The PR column does not drop under narrow-width layout branches, so very small terminals first hide stage and status before sacrificing the PR signal.

The grid view derives its visible snapshot through scope, slug/name/id filter, and `Snapshot#without_old_archived`. That drops `9-done` rows older than 3 days by row `mtime` (the same state-file timestamp rendered as task age), falling back to `folder_mtime` only for legacy payloads. Marker state is intentionally ignored: complete, unresolved, and markerless done rows all hide by the same age rule. Rows with neither timestamp fail open and stay visible. Cursor movement and `BubbleModel#current_row` use the same filtered projection, so keystrokes cannot dispatch against a hidden row. The default footer does not surface the hidden-archive count; `z` opens the Archive pane when the operator wants the unfiltered archive list. The Archive pane itself renders directly from the unfiltered snapshot and therefore lists every `9-done` task regardless of age.

Snapshots carry a `current_seen_at` timestamp; if the last successful refresh is older than 5s, the header renders a `[stalled: Xs]` banner and the `@last_error` message is surfaced in the status line. The previous snapshot stays visible — the loop never crashes on a transient JSON / IO error.

`Update.apply_snapshot_arrived` re-resolves `model.cursor` against the new snapshot by **following the selected slug**, not the prior `[project_idx, row_idx]` coords. On each poll it captures the slug at the cursor in the OLD visible snapshot and looks it up in the NEW visible via `cursor_for_slug(visible, slug, prior_project_idx)`. The helper prefers the prior project — slugs are not globally unique across projects, so an identically-named row in another project must not silently steal the cursor — then falls back to a global scan across all projects so a task that migrates project boundaries (or whose row order shifted because a peer above it advanced a stage) still keeps the highlighted row aligned with the row that `s`/Enter will dispatch against. When the slug is gone from the new visible (archived, filtered out, or finalized) the cursor falls back to coord-preserving `reclamp_cursor`: keep the coords if they are still in bounds, otherwise jump to the first visible row so downstream `apply_cursor_*` handlers do not get wedged on invalid coords. The previous coord-only reclamp (landed 2026-04-28) covered drop/truncate snapshot deltas but missed in-bounds reorderings under the cursor — the silent-wrong-dispatch class that motivated the slug-follow upgrade. See [[log]] 2026-06-03 for the evolution.

## Subprocess dispatch

Workflow verbs default to background dispatch: `Hive::Tui::Subprocess.dispatch_background(argv, dispatch:)` `Process.spawn`s the child detached into its own pgroup with stdout/stderr captured to a per-spawn file (see below), returns immediately, and a reaper Thread waits for the child and dispatches `Messages::SubprocessExited(verb:, exit_code:)` so the TUI flashes the result. Recoverable-marker gestures do not use this subprocess path: a worker submits the observed row through `Hive::Recovery::API` and renders the coordinator receipt. The renderer keeps painting and multiple agents across multiple projects run concurrently. `Hive::Workflows::VERBS` carries an optional `interactive: true` flag for verbs that need the user's tty (stdin prompts); none of the v1 verbs are flagged interactive, so every ordinary workflow keystroke takes the background path today.

Interactive-flagged verbs would route through `Hive::Tui::Subprocess.takeover_command(argv, dispatch:)`, which returns a `Bubbletea::SequenceCommand` of three steps: exit alt-screen, run a callable synchronously inside the framework's suspend window (raw mode disabled, cursor shown, input reader stopped), then re-enter alt-screen. The callable spawns the child with stdio inherited, blocks on `Process.wait2`, and dispatches `Messages::SubprocessExited(verb:, exit_code:)` so the user sees the same flash. Used only for verbs that genuinely need the tty.

`needs_input` rows use the same alt-screen suspension pattern, but for the row's input file instead of a workflow verb. Pressing `Enter` opens the stage state file (`brainstorm.md`, `plan.md`, `task.md`, `pr.md`) in `$VISUAL`, `$EDITOR`, or `vi` so the user can fill inline answers. For `:review_waiting`, the editor targets the **focal file** of the resume:

- `reason=fix_guardrail` rows open `reviews/fix-guardrail-NN.md` directly so a `[x]` tick of every line drives the U5 approval-on-resume in [[stages/review]] (Phase 4). Missing focal file falls back to the `reviews/` directory.
- Escalations-only `:review_waiting` rows (no `reason` attr) open the single unresolved reviewer-authored file when there is one, else fall back to the `reviews/` directory.

The takeover handler reuses `Hive::Tui::Subprocess.foreground_takeover_command` and samples mtime before/after the spawn so the post-edit `Messages::InputEditorExited(slug:, exit_code:, changed:)` flash distinguishes a saved edit from a no-op cancel. It also samples the file's checkbox-count Hash (`{checked: N, unchecked: M}`) for `review_outcome`'s 6-review auto-continue gate — a separate signal from `changed:` because mtime-only is not strict enough to avoid no-op review re-runs.

Pressing `o` from grid mode opens the focused row's task folder in `$EDITOR` for read-only browsing — distinct from `Enter` (workflow-contextual: editor on `needs_input`, log tail on `agent_running`, recover+rerun on review/error recovery rows, etc.) and the verb keys (which dispatch a `hive <verb>` subprocess). `o` mutates no marker, dispatches no workflow, and emits no follow-up `Messages::InputEditorExited` — the editor's exit is the user's last word. Useful for revisiting investigation outputs in `9-done` (or any stage) without dropping to a shell. The handler reuses the same `foreground_takeover_command` machinery `Enter`-on-`needs_input` uses, so terminal handoff is identical; only the after-spawn plumbing differs.

Pressing `i` from grid mode opens a full-screen read-only info panel for the focused task. `BubbleModel#open_idea_preview` reads the task's `idea.md` once, builds `Hive::Tui::Model::InfoPanelState`, and the view renders common identity fields (slug, stage, `created_at`, absolute stage folder, latest `.hive-state/logs/<slug>/*.log` path, and original idea text). Stage extras are plain-text snapshots: `brainstorm.md` for `2-brainstorm`, `plan.md` for `3-plan`, the latest execute-log tail for `4-execute`, and no extra block for `1-inbox`. The panel uses the existing `:idea_preview` mode and `OpenIdeaPreview` / `Back` messages; it mutates no files and spawns no subprocess. Only `q`, `Esc`, or `i` closes it, so accidental unmapped keys are no-ops.

The idea composer and read-only preview share
`Views::Format.character_chunks` for fixed-width character slicing. Composer
cursor placement, attachment badges, row-windowing, and preview panel fitting
remain view-specific.

Pressing `s` from grid mode is the manual-steering escape hatch. `KeyMap` emits `Messages::OpenInAgent`, and `BubbleModel` resolves the task's project config, looks up `execute.agent`, verifies the feature worktree exists, then writes `MANUAL_STEERING` to the row's state file before handing the terminal to the configured development agent in that worktree. Existing stage folders for the slug are passed in `Hive::Stages::DIRS` order with the agent profile's add-dir flag, so the agent can read the idea, brainstorm, plan, task, logs, reviews, and later-stage artifacts without the operator copying paths by hand. `MANUAL_STEERING` classifies as `manual_steering` with no suggested command, so `hive run`, the daemon policy, and workflow verb keys skip it. When the interactive agent exits, `Messages::AgentSteerExited` moves the active stage folder to `.hive-state/stages/archived-manual/<slug>/` (or a numeric suffix on collision), which makes the slug disappear from `hive status` and the TUI without treating it as an `9-done` pipeline archive.

Execute-stage waiting rows read `row.next_action` from `hive status --json`: `kind=edit` opens the reason-specific target (`worktree`, `plan.md`, or `task.md`), while `kind=run` dispatches the suggested `hive develop ... --from 4-execute` command directly for recovery states like `missing_research_output` where editing a file cannot clear the gate.

Three stages get an auto-continue convenience after the editor exits cleanly:

- **2-brainstorm:** if the file changed, the current file marker is still `WAITING` / `none`, and the latest `## Round N` has every `### Qn` paired with a non-empty `### An`, the TUI dispatches the row's existing `hive brainstorm ... --from 2-brainstorm` suggested command automatically.
- **3-plan:** if the editor exits `0`, the marker is still `:waiting`, and `row.suggested_command` is parseable as `hive plan ...`, the TUI builds a swapped-verb `hive develop ... --from 3-plan` dispatch, then flips the plan-stage marker `:waiting → :complete` (atomic-rename via `Hive::Markers.set`, guarded by a compare-and-set re-read that raises `MarkerRaceError` if the marker drifted to a different state during the edit). The marker flip is the "user approved the plan as-is" signal made explicit on disk — `hive develop --from 3-plan` requires `:complete` on the source stage and would otherwise fail silently in background. The build-then-flip order is load-bearing: a malformed `suggested_command` raises before the marker write, leaving `:waiting` intact so the user can re-trigger after fixing the row. Editing the plan and saving with changes routes to `:revise_plan` instead (re-runs `hive plan` with the user's edits as feedback); the marker is NOT flipped on that path.
- **6-review (U6):** if the file's `[x] / [ ]` checkbox set actually changed (a bare `:wq` with no checkbox flips returns `:silent` and skips dispatch — protects against no-op runner round-trips), the marker is still `:review_waiting`, and `row.suggested_command` is non-empty, the TUI dispatches `hive run` automatically and surfaces a confirming flash (`approved — starting next review pass for <slug>`).

Partial brainstorm answers, stale rows whose marker changed while the editor was open, and any other stage's `:waiting` state stay manual; workflow verb keys (`b` / `p` / `d` / `r` / `P`) remain the explicit rerun path. Note: partial `[x]` ticks on `fix-guardrail-NN.md` and edits that truncate findings (changing the marker's `matches` count) are rejected by [[stages/review]]'s `fix_guardrail_approved?` and keep the pause — the TUI may still dispatch, but the runner re-fires the same `:review_waiting reason=fix_guardrail` marker.

## Red-status detail mode

Red rows still show the concrete marker details in the grid status column, but selected rows now open a full-screen Q&A detail view before clearing anything. The view renders `row.diagnostic` from `hive status --json`:

- `Q: Why is this red?` uses the bounded local/agent diagnostic summary and detail.
- `Q: What can Hive do next?` names the available action.
- `Artifacts` lists the exact files Hive used to explain the row.

The goal is "auto-fix first, ask only when needed." `Enter` inside the detail view runs the same recovery path that grid Enter used to call directly and closes the screen on dispatch (success or refusal); rows with no automatic recovery recipe surface a refusal flash naming `Open in agent` and still close the screen so the operator's binary gesture never strands them on a stale view. `o` invokes the manual-steering takeover — same path as grid `s` — and closes the detail screen as the agent suspends the TUI; on agent exit the operator lands back on the grid rather than a stale detail view.

Snapshot polling keeps the view honest. If the row disappears, the detail view closes with `<slug> no longer in this project`. If the row recovers to a non-red action, it closes with `<slug> recovered - status updated`. If the marker changes under the open view, the cached row updates in place silently — the next time the operator re-opens the screen they see the fresh diagnosis.

The grid still preserves the established direct paths where the right answer is already known:

- `REVIEW_STALE reason=wall_clock` retries directly; there may be no reviewer file to inspect yet.
- Max-passes `REVIEW_STALE` with `reviews/escalations-NN.md` opens that file, preserving the browse/edit then `r` retry gesture.
- Kill-class `ERROR reason=exit_code exit_code=130|137|143` opens the log tail while background auto-heal clears the interruption marker; kill-class numeric codes with another reason stay recoverable.
- `recover_execute` rows keep the old findings/recovery hint; there is no autofix detail action in v1.
- Every `ERROR` / `REVIEW_ERROR`, including `fix_status_check_failed` and `ensure_clean_on_exit_failed`, offers a generation-guarded retry. The daemon may temporarily defer the retry while the current work area is dirty or awaiting operator input; after files, configuration, or agent availability changes, the next eligible retry revalidates the task from current state. `EXECUTE_STALE` remains manual because it represents unresolved findings rather than a failed attempt.

`recover_review` rows show the observed recovery cause in the status column (for example `merge_conflict` from `<!-- REVIEW_ERROR phase=triage reason=merge_conflict pass=2 -->`, or `stale pass=N` for a `REVIEW_STALE` max_passes-hit row that carries the runner's pass attr) instead of the generic `Needs recovery` label; control bytes and ANSI CSI escapes embedded in the reason are stripped through `Hive::Tui::Text.sanitize` before render so a stdout-tail snippet captured into the marker cannot corrupt column alignment or hijack the cursor. A background worker submits the complete observed row through `Hive::Recovery::API`, keeping the bubbletea render loop non-blocking, and flashes the coordinator's canonical receipt. Grid Enter opens red-status detail for ambiguous `REVIEW_ERROR` / `REVIEW_CI_STALE` rows; Enter inside that detail view starts this recovery. `REVIEW_STALE` permits coordinator submission in two retryable cases:

- **`reason=wall_clock`**: the runner's aggregate wall-clock budget elapsed mid-phase. The operator's correct response is "give it more time and retry"; this can fire BEFORE any reviewer files exist (e.g. during Phase 1 CI-fix), and a missing-file state has no operator action to take, so retry must not require reviewer-file presence.
- **incomplete-triage shape**: the highest pass has reviewer files but no matching `reviews/escalations-NN.md` — triage never completed and the same pass is retryable.

The synchronous return flashes `Checking recovery…`; the worker dispatches a follow-up `Messages::Flash` with queued, cooldown, running, blocked, or terminal truth. A second `Enter` on the same folder while the local worker is still in flight refuses with an `already in progress` flash (`@review_recovery_inflight`), while coordinator request identity deduplicates across processes. System I/O errors become an explicit failure flash; programmer errors still surface instead of being misattributed to a recovery failure.

For other `REVIEW_STALE` rows (max_passes hit with completed passes), Enter routes to a browse-only handler — `BubbleModel#open_review_stale_file` — that opens the highest-pass `reviews/escalations-NN.md` (derived from `marker.attrs["pass"]`) in `$VISUAL` / `$EDITOR` / `vi` via the same `foreground_takeover_command` machinery `o` and `Enter`-on-`needs_input` use. The marker is NOT cleared and no request is submitted on Enter — retrying without edits would just produce the same findings, so the gesture-pair is split: **Enter to browse and edit; `r` to force-retry after editing**. The `r` verb-key path emits `Messages::RecoverReview.new(row:, force: true)`; the `force` flag bypasses `retryable_review_stale?` and submits the observation to the coordinator. Only `r` takes this path. If `escalations-NN.md` is missing for the recorded pass, the resolver falls back to the `reviews/` directory; if neither exists, the Enter handler flashes `no review files for <slug>` and refuses.

Note that `REVIEW_STALE reason=wall_clock` deliberately retries even when no reviewer files exist for the recorded pass — wall-clock can fire during Phase 1 CI-fix, before any reviewer ran. The pre-fix gate told the operator to "edit/rename highest-pass review files" but in that scenario there are no files to edit. Retry the run, and if wall-clock keeps firing, the operator's lever is `review.max_wall_clock_sec` in `<project>/.hive-state/config.yml`.

`error` rows distinguish explicit signal-kill markers from other structured failures. Kill-class codes (`130` / `137` / `143`, hosted on `Hive::Markers::KILL_CLASS_EXIT_CODES`) only take the auto-heal/log-tail path when the marker also carries `reason=exit_code`; the background auto-healer submits those observations to the same coordinator. Attempts are keyed by folder and throttled by `HEAL_REPEAT_INTERVAL_SECONDS` (60s), so persistent local failures cannot spawn one thread per status snapshot. Every other shape, including a kill-class numeric code with a different reason such as `reason=shutdown exit_code=143`, is treated as a recoverable error: grid Enter opens red-status detail first, and Enter in that view routes through `RecoverError` on a background worker. The status column shows `ERROR exit_code=N` (or `ERROR <reason>` when no exit code is set) so the operator can read why the agent failed without leaving the grid. Per-folder local dedup is tracked on `@error_recovery_inflight`; cross-process dedup and marker occurrence safety are coordinator-owned.


`SUBPROCESS_LOG_PATH` (`$TMPDIR/hive-tui-subprocess.log`, or `$HIVE_TUI_LOG_DIR/hive-tui-subprocess.log` when the e2e harness scopes a run) is a marker-only log: BEGIN[id] / END[id] / ERRNO records, no child stdio. Each background spawn captures its own stdout/stderr to `hive-tui-spawn-<id>.log` in the same directory (the same 8-char hex ID embedded in the marker line). The reaper deletes the per-spawn capture on `exit_code == 0` (success has nothing to diagnose) and keeps a truncated failure capture on non-zero exits; `Messages::SubprocessExited` carries the spawn id so `Subprocess.diagnose_recent_failure(verb, spawn_id:)` reads the exact failed subprocess instead of whichever same-verb BEGIN marker is newest. Diagnosis starts with the last 64 KiB of marker lines and walks backward in 64 KiB increments up to 1 MiB before falling back to the generic exit-code flash; this keeps lookup bounded while tolerating bursts of concurrent marker traffic after a failed spawn. `SUBPROCESS_LOG_MAX_BYTES` (10 MiB) is checked at each stamp write — when exceeded the file is renamed to `…log.1` (single rotation tier). With child output redirected away from the shared file, that cap is now an actual disk-usage bound rather than the approximate ceiling it used to be. Per-spawn captures are reaped opportunistically: every BEGIN sweeps `hive-tui-spawn-*.log` in the active log directory and deletes anything older than 24 h so a crashed reaper or a `kill -9 hive` can't leak files.

## Terminal hostility

- **Resize:** `App.run_charm` installs a Hive-owned `SIGWINCH` hook before `Runner#run`, seeds the current `STDOUT.winsize`, and dispatches `Messages::WindowSized` directly; Bubble Tea still chains through that hook and owns renderer sizing. `BubbleModel#update` also translates framework `WindowSizeMessage` values, so both the app hook and the framework path converge on `model.cols`/`model.rows`.
- **Ctrl+Z / SIGTSTP:** Bubble Tea owns suspend/resume of the alt-screen and raw-mode toggling.
- **SIGHUP:** trapped at boot in `App.run_charm`; the trap calls `runner.send(Messages::TERMINATE_REQUESTED)`, which the runner picks up at the top of the next loop tick. Update returns `Bubbletea.quit` so the runner exits cleanly. Cleanup runs in `App.run_charm`'s `ensure` (kill the polling thread, stop StateSource, restore the previous HUP/WINCH handlers, `SubprocessRegistry.kill_inflight!`, reap inflight auto-heal threads). All setup (StateSource boot, `Bubbletea::Runner` construction, signal hook install, poller spawn) is performed *inside* the same `begin` so a constructor failure still hits the same nil-guarded cleanup path — the StateSource thread can no longer leak when `Bubbletea::Runner.new` raises.
- **Crash-time cleanup:** there is no `at_exit` hook. Workflow-verb children are spawned with `pgroup: true` and intentionally **detached** — `dispatch_background` never registers them with `SubprocessRegistry`, and the registry's `kill_inflight!` is called only from `App.run_charm`'s normal-exit `ensure` block (not from `at_exit`). A signal that bypasses that ensure (`SIGKILL` of the TUI, kernel OOM kill, etc.) leaves the children running. That is the design — long-running background agents outlive an interrupted dashboard so the user can re-attach with `hive tui` and pick up the in-flight rows. Recovery for kill-class markers landing on a re-launched TUI happens via `auto_heal_kill_class_errors`, not via at-exit cleanup.
- **`--json`:** rejected at the command boundary with EX_USAGE (64); the TUI is human-only by design. The reject path emits a structured error envelope on stdout (`{"ok":false, "error_class":"InvalidTaskPath", "error_kind":"invalid_task_path", "exit_code":64, "message":...}`) so JSON consumers see typed error data without a `SCHEMA_VERSIONS` bump (the envelope intentionally omits `schema` because `hive tui` has no registered `hive-*` schema, and `error_kind` matches the value other `InvalidTaskPath` emit sites already use).
- **Non-tty boundary:** running `hive tui` with `$stdout` not a tty (e.g., a piped CI invocation) raises `Hive::InvalidTaskPath` and exits 64 (EX_USAGE) — same code as `--json` rejection, so wrappers branch on a single "this is a misuse, not a software fault" surface.

## Test surface

- `test/integration/tui_command_test.rb` — Thor help-text registration, `--json` rejection, non-tty boundary check.
- `test/unit/tui/*_test.rb` — pure-Ruby state machines (`StateSource`, `Snapshot`, `KeyMap`, `GridState`, `LogTail::FileResolver`, `Help`, `Model`, `Messages`, `Update`, `BubbleModel`). The help overlay path pins explicit close keys, scroll-key mapping, offset clamping, resize reclamping, and mouse-wheel translation.
- `test/unit/tui/views/*_test.rb` — pure-function view tests for every Lipgloss-rendered frame (`ProjectsPane`, `TasksPane`, `LogTail`, `RedStatusDetail`, `HelpOverlay`, `FilterPrompt`, `IdeaPreview`, `NewIdeaPrompt`). Layout/text content is pinned; `HelpOverlay` additionally covers bounded height, wrapping, scrollbar rendering, and the tiny-terminal fallback. Visual styling (color/bold/reverse) is validated by manual dogfood — lipgloss-ruby v0.2.2 strips ANSI in non-tty test environments (gap tracked in `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md`). Selection / cursor highlight predicates (`ProjectsPane#selected?`, `TasksPane#highlight?`) are exposed for unit-test assertion since the rendered output cannot distinguish them in non-tty.
- `test/integration/tui_subprocess_test.rb` — `Subprocess.takeover_command` / `run_quiet!` against a fake child binary.
- `test/integration/tui_smoke_test.rb` + `test/integration/tui_smoke_charm_test.rb` — PTY-based boot smokes: `bin/hive tui` paints, the seeded project name appears without a multi-second loading grid on the startup path (a generous 5s regression bound, not a benchmark), `q` exits 0, and the charm smoke resizes a running PTY horizontally and vertically, sends `SIGWINCH`, and asserts the next frame expands while keeping the footer visible.

No render-layer snapshot tests beyond layout pinning; mainstream Ruby tooling does not provide cell-perfect terminal-snapshot diffing.

## Backlinks

- [[cli]] · [[commands/status]] · [[commands/drop]] · [[commands/findings]] · [[commands/stage_action]]
- [[modules/task_action]] · [[modules/workflows]] · [[modules/findings]]
