---
title: Background-spawn dispatch and signal-aware marker healing for headless TUI agents
date: 2026-04-28
category: architecture-patterns
module: Hive::Tui
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - Building a TUI or dashboard that dispatches long-running subprocess workers from interactive keybindings
  - Child processes already capture their own stdio (log files via IO.pipe) and do not require the user's tty
  - Workers may be killed mid-run by signal propagation (e.g., SIGTERM through a process group on supervisor exit)
  - Workflow state is reconstructed from sidecar artefacts (marker files, folder layout) rather than process exit codes
  - Multiple concurrent workers must run across independent projects without blocking the supervisor UI
tags:
  - tui
  - bubbletea
  - subprocess-dispatch
  - process-groups
  - signal-handling
  - auto-heal
  - state-machine
  - hive-pipeline
---

# Background-spawn dispatch and signal-aware marker healing for headless TUI agents

## Context

The `hive tui` Charm-bubbletea backend originally dispatched workflow verbs (`hive develop`, `hive pr`, etc.) via a foreground takeover: a `Bubbletea.sequence(exit_alt_screen, …, enter_alt_screen)` wrapper around a synchronous `Process.spawn(*argv, pgroup: true)` so the child got the user's terminal. This produced two coupled UX problems verified during dogfood:

1. **TUI froze for the entire duration of the agent run.** The user reported: *"when I just run hello world test it blocks the screen while agent running — which is strange — multiple agents can run for multiple projects it's not a reason to bloc tui"*. Agents that take minutes locked out every other interaction.
2. **Quitting the TUI mid-run left tasks stuck in `:error reason=exit_code exit_code=143`.** Pressing `q` triggered the runner's pgroup cleanup, which forwarded SIGTERM to the in-flight verb. The agent's `handle_exit_state_file_marker` wrote an `:error` marker on its way out. The task's workspace files (`idea.md`, `brainstorm.md`, `plan.md`, `task.md`, `pr.md`) were all intact — only the marker said "stopped". But the TUI classified the row as "Error" indefinitely and the user had to run `hive markers clear <slug> --name ERROR` from a sibling shell to recover.

The framing the user pushed back with: *"the big benefit of having files based system as we can just resume state from files"*. The pipeline already records every state transition on disk — the runner doesn't need to own the agent's lifecycle, and a signal-killed marker is *interrupted*, not *broken*.

## Guidance

Two coupled patterns, shipped together because the second is enabled by the first:

### Pattern 1 — Background-spawn for headless workers

Workflow verbs that already capture their own stdio (`Hive::Agent` writes via `IO.pipe` to `task.log_dir/<label>-<ts>.log`) should NOT be foreground-takeover candidates. The right shape:

- `Process.spawn(*argv, pgroup: true, out: [LOG, "a"], err: [LOG, "a"])` — child writes to a stable log path; nothing touches the alt-screen.
- Reaper Thread waits on the child and dispatches `Messages::SubprocessExited(verb:, exit_code:)` so the supervisor can flash the result.
- Returns `nil` (no Bubbletea Cmd) — the runner's render loop keeps spinning while the agent runs in parallel.
- No INT/TERM trap forwarding, no `SubprocessRegistry` slot — children are detached into their own pgroup. SIGHUP on the supervisor lets background children continue independently (a long brainstorm finishes even if the user quits).

```ruby
def dispatch_background(argv, dispatch:)
  verb = argv[1]
  pid = Process.spawn(*argv, pgroup: true,
                     out: [SUBPROCESS_LOG_PATH, "a"],
                     err: [SUBPROCESS_LOG_PATH, "a"])
  Thread.new do
    _, status = Process.wait2(pid)
    exit_code = translate_status(status)
    dispatch.call(Messages::SubprocessExited.new(verb: verb, exit_code: exit_code))
  end
  nil
end
```

A synchronous "running …" flash fires from the supervisor side at dispatch time (`BubbleModel#dispatch_command`) so the user gets immediate keypress feedback — the spawn is async but the visual confirmation is not.

### Pattern 2 — Auto-heal kill-class markers

When the supervisor's snapshot poll surfaces a task with `:error reason=exit_code exit_code=N` where N ∈ {130, 137, 143} (SIGINT, SIGKILL, SIGTERM respectively), the supervisor clears the marker in the background:

```ruby
KILL_CLASS_EXIT_CODES = %w[130 137 143].freeze

def auto_heal_kill_class_errors(snapshot)
  snapshot.rows.each do |row|
    next unless kill_class_error?(row)
    next if @healed_folders.key?(row.folder)
    @healed_folders[row.folder] = Time.now
    Thread.new { Subprocess.run_quiet!([ "hive", "markers", "clear", row.folder, "--name", "ERROR" ]) }
  end
end
```

Per-folder dedup prevents thrashing. The next snapshot poll picks up the cleared marker and the row re-classifies (typically back to "Ready for X" because the agent's pre-kill workspace is preserved).

**Real failures (`exit_code=1`, `reason=timeout`, `reason=secret_in_pr_body`) are NOT auto-healed.** Only kill-class signals get the auto-heal — those reflect "the supervisor or user interrupted me", not "I ran and decided to fail".

## Why This Matters

**The TUI is a supervisor, not a host.** Conflating the two — making the TUI block on every child — wastes the file-system's write-everything-down architecture. The pipeline already encodes every meaningful transition (markers + folder moves), so the supervisor only needs to *display* state, not *own* state.

The two patterns reinforce each other:

- Pattern 1 (background-spawn) makes the supervisor concurrent, which surfaces a new edge case: SIGTERM-on-quit can leave dozens of in-flight children with stuck markers.
- Pattern 2 (auto-heal) addresses that edge case by treating kill-class signals as "interrupted, recoverable from disk", not "broken, manual intervention required".

Without both, the TUI is either single-tasking (foreground takeover) or accumulating stuck-error rows after every quit-while-running (background spawn alone). Together: multi-agent concurrency + self-recovering display.

This generalizes beyond Hive. Any TUI dispatching subprocess workers whose state lives in files (review queues, queue dashboards, batch-job runners) wins from the same shape.

## When to Apply

- Children already capture their own stdio (log file, `IO.pipe`) — no need for the user's tty.
- State-machine transitions are recorded on disk, not in-memory in the supervisor.
- Multiple concurrent workers are valuable — the user wants to dispatch on row A, then row B, then row C without waiting.
- Children may be killed by signal (Ctrl-C on the supervisor, `q` while a verb runs, `kill -TERM`) — the supervisor needs a recovery story for the resulting markers.

### Per-verb interactive opt-in (escape hatch)

The pattern intentionally keeps a per-verb interactive flag so a future verb that DOES need stdin (a manual review prompt, an interactive `gh pr create`, claude tool-permission asks if ever non-headless) can opt in without re-introducing foreground takeover for everything. In Hive, this is `Hive::Workflows::VERBS["<verb>"][:interactive] = true`; `Hive::Workflows.interactive?(verb)` returns the flag; `BubbleModel#dispatch_command` routes interactive verbs through `Subprocess.takeover_command` (returns a `Bubbletea::SequenceCommand(exit_alt, exec, enter_alt)`) and headless verbs through `Subprocess.dispatch_background` (returns nil; the runner keeps polling).

Default is non-interactive. v1 ships with no verbs flagged interactive — every workflow agent currently runs claude with captured stdio and `gh pr create` works non-interactively for `hive pr`. The flag is the lever for *when a real verb needs it*, not a hypothetical.

Do **not** apply the background-spawn shape when:

- The supervisor's lifecycle should own the worker's lifecycle (e.g., a debugger attaching to a child must control its own teardown).
- The child's stdout is the user's diagnostic feedback (in which case foreground takeover is the simpler UX).

## Examples

**Before — foreground takeover (single-tasking, alt-screen bleed risk):**

The original `takeover_command` returned a Bubbletea sequence wrapping a synchronous spawn-and-wait callable. Inside the callable, `Process.spawn` + `Process.wait2` ran on the runner's main thread, blocking every other render and keystroke for the duration of the verb. Concurrent dispatches were impossible.

**After — background-spawn (concurrent, no alt-screen toggle):**

```ruby
def dispatch_background(argv, dispatch:)
  verb = argv[1]
  pid = Process.spawn(*argv, pgroup: true,
                     out: [SUBPROCESS_LOG_PATH, "a"],
                     err: [SUBPROCESS_LOG_PATH, "a"])
  Thread.new do
    _, status = Process.wait2(pid)
    exit_code = translate_status(status)
    dispatch.call(Messages::SubprocessExited.new(verb: verb, exit_code: exit_code))
  end
  nil
end
```

**Verified end-to-end (production dogfood):**

The `add-ruby-version-requirement-to-260425-ff9b` task in writero was previously stuck on `:error exit_code=143` (killed mid-`hive pr` when the user pressed `q`). After the patterns shipped:

1. TUI booted → `auto_heal_kill_class_errors` cleared the marker in the background
2. Next snapshot poll → row re-classified as "Ready for PR"
3. User pressed `P` → background-spawn fired `hive pr` → flash showed ``running `hive pr add-ruby-version-...`…``
4. TUI stayed responsive throughout; user navigated other projects in parallel
5. Reaper Thread caught the exit (0) ~42 seconds later → flash updated
6. Next press of `a` → archive dispatch → exit 0
7. Task at `7-done`, marker complete, end-to-end without leaving the TUI

**Subprocess log per-section structure** (enables verb-aware diagnostics later):

```
----- 2026-04-28T10:55:21Z BEGIN: hive pr add-ruby-version-requirement-to-260425-ff9b --project writero --from 5-review -----
hive: marker=complete
  state_file: …/pr.md
  next: hive archive add-ruby-version-…
----- 2026-04-28T10:56:03Z END exit=0: hive pr add-ruby-version-requirement-to-260425-ff9b --project writero --from 5-review -----
```

Each spawn produces one BEGIN / END pair around its captured stderr, allowing later passes (e.g., `Subprocess.diagnose_recent_failure`) to extract per-verb sections for targeted error messages without reading the full log.

## Related

- `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md` — verifies the bubbletea-ruby v0.1.4 API surface; documents that the takeover callable doesn't propagate exit codes (the original reason for the closure-capture pattern these fixes evolved out of). Shares one referenced file (`lib/hive/tui/subprocess.rb`) but covers a distinct gap (lipgloss color-rendering on non-tty stdout).
- Plan `docs/plans/2026-04-27-003-refactor-hive-tui-charm-bubbletea-plan.md` — the migration plan whose R3 / KTD-4 / U6 specified the now-superseded foreground takeover model. The background-spawn pattern documented here replaces the takeover sections of that plan; refresh of the plan doc is out of scope for this learning but flagged for a future `/ce-compound-refresh` pass.
- `Hive::Commands::Markers` — the agent-callable healer the auto-heal dispatches against (`hive markers clear FOLDER --name ERROR`).
- Commits on `feat/hive-tui`: `6eae7e5` (auto-heal + background-spawn), `bd2013f` (running-flash for immediate feedback), `88012bc` (per-pattern diagnostic flashes that build on the per-section log structure).
