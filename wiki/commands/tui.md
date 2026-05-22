---
title: hive tui
type: command
source: lib/hive/tui.rb
created: 2026-04-27
updated: 2026-05-22
tags: [command, tui, observability, interactive, diagnostics]
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
│  myapp          │  ⚠  oauth-…       6-review      Needs recovery      1h │
│  appcrawl       │                                                        │
├─────────────────┴────────────────────────────────────────────────────────┤
│ Footer: [Tab] switch  [Enter] action  [n] new  [/] filter  [?] help  [q]│
└──────────────────────────────────────────────────────────────────────────┘
```

Pane focus is keyboard-only; the focused pane border is bright cyan, the inactive pane border is faint. Below 70 cols the project pane is suppressed and the tasks pane occupies the full width — narrow terminals still get a usable view, just without the left-pane drill-down.

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
| Help overlay | `?` | any key |

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
| `s` | steer the focused task manually: open the configured `execute.agent` in the feature worktree with every existing stage folder for that slug passed as agent context, mark the row `MANUAL_STEERING`, and archive the slug under `archived-manual/` when the agent exits |
| `n` | open the new-idea flow; if scope is `★ All projects`, first show a project picker, then submit with `hive new <project> "<title>"` against the chosen concrete project |
| `/` | open filter prompt |
| `1`–`9` | scope the right pane to the Nth registered project (mirrors selection in the left pane) |
| `0` | scope back to `★ All projects` |
| `X` | deregister the scoped project — gated to entries whose status is `(missing)` (i.e. `error: "missing_project_path"`); healthy / not-initialised projects refuse with a flash that points at `hive forget`. Bulk version: `hive prune`. See [[commands/forget]] / [[commands/prune]]. |
| `?` | help overlay |
| `q` | quit (default mode) |
| `Esc` | back to default mode (any sub-mode) |

Findings triage is no longer an in-TUI mode. Use `hive findings`, `hive accept-finding`, and `hive reject-finding` directly from a shell or coding agent; legacy `EXECUTE_WAITING findings_count` rows surface as `recover_execute` and point at `hive findings` from status JSON (see [[commands/findings]]). In red-status detail mode, `Enter` runs the existing autofix/retry path, `f` opens the task worktree in `$VISUAL` / `$EDITOR` / `vi`, `R` runs `hive status --diagnose <slug> --project <project> --write` in the background, and `q` / `Esc` returns to the grid. The help overlay groups bindings by mode for the disambiguation.

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

`Hive::Tui::StateSource` calls `Hive::Commands::Status#json_payload(Hive::Config.registered_projects)` in-process at 1 Hz from a non-daemon background thread. Read-only, no locks taken. The render thread reads `@current` once per frame; under MRI 3.4's GVL the pointer-sized reference write is atomic. JRuby/TruffleRuby would need a `Mutex`/`AtomicReference` upgrade — a `RUBY_ENGINE != "ruby"` boot guard makes the assumption auditable.

Snapshots carry a `current_seen_at` timestamp; if the last successful refresh is older than 5s, the header renders a `[stalled: Xs]` banner and the `@last_error` message is surfaced in the status line. The previous snapshot stays visible — the loop never crashes on a transient JSON / IO error.

`Update.apply_snapshot_arrived` reclamps `model.cursor` against the new snapshot's visible rows: a poll that drops the cursor's row (e.g. the last task in a project finishes and disappears, or the project list shrinks past `project_idx`) jumps the cursor to the first visible row instead of leaving it pointing at a hidden one — without this, downstream `apply_cursor_*` handlers refuse to move from invalid coords and j/k silently noop. Still-valid cursors are preserved across benign polls so the user's selection does not snap to the top each second.

## Subprocess dispatch

Workflow verbs default to background dispatch: `Hive::Tui::Subprocess.dispatch_background(argv, dispatch:)` `Process.spawn`s the child detached into its own pgroup with stdout/stderr captured to a per-spawn file (see below), returns immediately, and a reaper Thread waits for the child and dispatches `Messages::SubprocessExited(verb:, exit_code:)` so the TUI flashes the result. The renderer keeps painting and multiple agents across multiple projects run concurrently. `Hive::Workflows::VERBS` carries an optional `interactive: true` flag for verbs that need the user's tty (stdin prompts); none of the v1 verbs are flagged interactive, so every workflow keystroke takes the background path today.

Interactive-flagged verbs would route through `Hive::Tui::Subprocess.takeover_command(argv, dispatch:)`, which returns a `Bubbletea::SequenceCommand` of three steps: exit alt-screen, run a callable synchronously inside the framework's suspend window (raw mode disabled, cursor shown, input reader stopped), then re-enter alt-screen. The callable spawns the child with stdio inherited, blocks on `Process.wait2`, and dispatches `Messages::SubprocessExited(verb:, exit_code:)` so the user sees the same flash. Used only for verbs that genuinely need the tty.

`needs_input` rows use the same alt-screen suspension pattern, but for the row's input file instead of a workflow verb. Pressing `Enter` opens the stage state file (`brainstorm.md`, `plan.md`, `task.md`, `pr.md`) in `$VISUAL`, `$EDITOR`, or `vi` so the user can fill inline answers. For `:review_waiting`, the editor targets the **focal file** of the resume:

- `reason=fix_guardrail` rows open `reviews/fix-guardrail-NN.md` directly so a `[x]` tick of every line drives the U5 approval-on-resume in [[stages/review]] (Phase 4). Missing focal file falls back to the `reviews/` directory.
- Escalations-only `:review_waiting` rows (no `reason` attr) open the single unresolved reviewer-authored file when there is one, else fall back to the `reviews/` directory.

The takeover handler reuses `Hive::Tui::Subprocess.foreground_takeover_command` and samples mtime before/after the spawn so the post-edit `Messages::InputEditorExited(slug:, exit_code:, changed:)` flash distinguishes a saved edit from a no-op cancel. It also samples the file's checkbox-count Hash (`{checked: N, unchecked: M}`) for `review_outcome`'s 6-review auto-continue gate — a separate signal from `changed:` because mtime-only is not strict enough to avoid no-op review re-runs.

Pressing `o` from grid mode opens the focused row's task folder in `$EDITOR` for read-only browsing — distinct from `Enter` (workflow-contextual: editor on `needs_input`, log tail on `agent_running`, recover+rerun on review/error recovery rows, etc.) and the verb keys (which dispatch a `hive <verb>` subprocess). `o` mutates no marker, dispatches no workflow, and emits no follow-up `Messages::InputEditorExited` — the editor's exit is the user's last word. Useful for revisiting investigation outputs in `9-done` (or any stage) without dropping to a shell. The handler reuses the same `foreground_takeover_command` machinery `Enter`-on-`needs_input` uses, so terminal handoff is identical; only the after-spawn plumbing differs.

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

The goal is "auto-fix first, ask only when needed." `Enter` inside the detail view invokes the same recovery path that grid Enter used to call directly. `f` opens the task worktree in the configured editor without clearing markers, for the "open worktree in development agent/fix manually" path. `R` asks the configured development agent for a fresh diagnosis by dispatching `hive status --diagnose <slug> --project <project> --write`; once the next snapshot lands, the view refreshes from `diagnostics/red-status.md` if its marker signature matches the current marker.

Snapshot polling keeps the view honest. If the row disappears, the detail view closes with `<slug> no longer in this project`. If the row recovers to a non-red action, it closes with `<slug> recovered - status updated`. If the marker changes under the open view, the row refreshes in place and the footer prompts the user to refresh diagnosis with `R`.

The grid still preserves the established direct paths where the right answer is already known:

- `REVIEW_STALE reason=wall_clock` retries directly; there may be no reviewer file to inspect yet.
- Max-passes `REVIEW_STALE` with `reviews/escalations-NN.md` opens that file, preserving the browse/edit then `r` retry gesture.
- Kill-class `ERROR exit_code=130|137|143` opens the log tail while background auto-heal clears the interruption marker.
- `recover_execute` rows keep the old findings/recovery hint; there is no autofix detail action in v1.

`recover_review` rows show the observed recovery cause in the status column (for example `triage_failed` from `<!-- REVIEW_ERROR phase=triage reason=triage_failed pass=2 -->`, or `stale pass=N` for a `REVIEW_STALE` max_passes-hit row that carries the runner's pass attr) instead of the generic `Needs recovery` label; control bytes and ANSI CSI escapes embedded in the reason are stripped through `Hive::Tui::Text.sanitize` before render so a stdout-tail snippet captured into the marker cannot corrupt column alignment or hijack the cursor. The recovery implementation sequences the documented CLI recovery flow on a background worker thread (mirroring `auto_heal_kill_class_errors` so the bubbletea render loop never blocks on `run_quiet!`'s 30 s upper bound): first `hive markers clear <folder> --name REVIEW_ERROR|REVIEW_CI_STALE`, guarded with one observed `--match-attr` when available, then `hive run <folder>` in the normal background-spawn path. Grid Enter now opens red-status detail for ambiguous `REVIEW_ERROR` / `REVIEW_CI_STALE` rows; Enter inside that detail view starts this recovery. `REVIEW_STALE` uses the same clear+rerun path in two retryable cases:

- **`reason=wall_clock`**: the runner's aggregate wall-clock budget elapsed mid-phase. The operator's correct response is "give it more time and retry"; this can fire BEFORE any reviewer files exist (e.g. during Phase 1 CI-fix), and a missing-file state has no operator action to take, so retry must not require reviewer-file presence.
- **incomplete-triage shape**: the highest pass has reviewer files but no matching `reviews/escalations-NN.md` — triage never completed and the same pass is retryable.

The synchronous return flashes `review recovery: clearing <detail>…`; the worker dispatches a follow-up `Messages::Flash` with the final result. A second `Enter` on the same folder while the worker is still in flight refuses with an `already in progress` flash instead of firing duplicate clear+rerun pairs (per-folder dedup tracked on `@review_recovery_inflight`, evicted in the worker's `ensure` block on completion). If the marker clear fails for any reason (concurrent-writer race via `--match-attr`, missing folder, transient I/O, etc.) the rerun is skipped and the captured stderr is flashed. If the clear succeeds but the rerun dispatch raises (Errno-class I/O failure, subprocess timeout) the flash explicitly says `marker cleared, but \`hive run\` failed to start: <reason>; run \`hive run <folder>\` manually` so the operator knows the system is half-cleared and which command will recover. Programmer errors (NoMethodError / NameError / ArgumentError) inside the worker are intentionally NOT swallowed by the rescue — only `SystemCallError`, `IOError`, and `Hive::Tui::Subprocess::TimeoutError` are caught — so logic bugs surface in logs instead of being misattributed to a recovery failure.

For other `REVIEW_STALE` rows (max_passes hit with completed passes), Enter routes to a browse-only handler — `BubbleModel#open_review_stale_file` — that opens the highest-pass `reviews/escalations-NN.md` (derived from `marker.attrs["pass"]`) in `$VISUAL` / `$EDITOR` / `vi` via the same `foreground_takeover_command` machinery `o` and `Enter`-on-`needs_input` use. The marker is NOT cleared and no `hive run` dispatch fires on Enter — clearing without edits would just produce the same findings on the next pass, so the gesture-pair is split: **Enter to browse and edit; `r` to force-retry after editing**. The `r` verb-key path emits `Messages::RecoverReview.new(row:, force: true)`; the `force` flag bypasses `retryable_review_stale?` in `BubbleModel#recover_review` and falls through to the same clear+rerun path the wall_clock / incomplete-triage shapes use (`hive markers clear <folder> --name REVIEW_STALE` then `hive run <folder>`). Only `r` (semantically a retry of the review stage) takes this path — other verbs (`b`/`p`/`d`/`P`) on the same row keep flashing "no action available" because dispatching them on a stale review row would be wrong. If `escalations-NN.md` is missing for the recorded pass, the resolver falls back to the `reviews/` directory; if neither exists, the Enter handler flashes `no review files for <slug>` and refuses.

Note that `REVIEW_STALE reason=wall_clock` deliberately retries even when no reviewer files exist for the recorded pass — wall-clock can fire during Phase 1 CI-fix, before any reviewer ran. The pre-fix gate told the operator to "edit/rename highest-pass review files" but in that scenario there are no files to edit. Retry the run, and if wall-clock keeps firing, the operator's lever is `review.max_wall_clock_sec` in `<project>/.hive-state/config.yml`.

`error` rows behave by exit_code. Kill-class codes (`130` / `137` / `143`, hosted on `Hive::Markers::KILL_CLASS_EXIT_CODES`) are signal kills (SIGINT / SIGKILL / SIGTERM); the background auto-healer in `BubbleModel#auto_heal_kill_class_errors` clears those `<!-- ERROR -->` markers on its own, so Enter on those rows falls through to the log-tail view rather than triggering a parallel clear that would race the auto-healer for the same markers-lock. Every other exit_code (`1`, `2`, anything outside the kill-class list, or markers with no exit_code attr at all) is a real failure the agent ran into; grid Enter opens red-status detail first, and Enter in that view routes through `RecoverError` on a background worker, mirroring the `recover_review` sequence: `hive markers clear <folder> --name ERROR --match-attr exit_code=N` (the match-attr ties the clear to the specific marker seen at snapshot time so a concurrent fresh failure with a different code is not erased), then `hive run <folder>` in the normal background-spawn path. The status column shows `ERROR exit_code=N` (or `ERROR <reason>` when no exit code is set) so the operator can read WHY the agent failed without leaving the grid. Per-folder dedup is tracked on `@error_recovery_inflight`; same partial-failure and programmer-error contracts as `recover_review`. The synchronous flash announces `error recovery: clearing ERROR …`; the worker dispatches a follow-up `Messages::Flash` with the outcome.


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
- `test/unit/tui/*_test.rb` — pure-Ruby state machines (`StateSource`, `Snapshot`, `KeyMap`, `GridState`, `LogTail::FileResolver`, `Help`, `Model`, `Messages`, `Update`, `BubbleModel`).
- `test/unit/tui/views/*_test.rb` — pure-function view tests for every Lipgloss-rendered frame (`ProjectsPane`, `TasksPane`, `LogTail`, `RedStatusDetail`, `HelpOverlay`, `FilterPrompt`, `NewIdeaPrompt`). Layout/text content is pinned; visual styling (color/bold/reverse) is validated by manual dogfood — lipgloss-ruby v0.2.2 strips ANSI in non-tty test environments (gap tracked in `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md`). Selection / cursor highlight predicates (`ProjectsPane#selected?`, `TasksPane#highlight?`) are exposed for unit-test assertion since the rendered output cannot distinguish them in non-tty.
- `test/integration/tui_subprocess_test.rb` — `Subprocess.takeover_command` / `run_quiet!` against a fake child binary.
- `test/integration/tui_smoke_test.rb` + `test/integration/tui_smoke_charm_test.rb` — PTY-based boot smokes: `bin/hive tui` paints, the seeded project name appears, `q` exits 0.

No render-layer snapshot tests beyond layout pinning; mainstream Ruby tooling does not provide cell-perfect terminal-snapshot diffing.

## Backlinks

- [[cli]] · [[commands/status]] · [[commands/findings]] · [[commands/stage_action]]
- [[modules/task_action]] · [[modules/workflows]] · [[modules/findings]]
