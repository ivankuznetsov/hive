---
title: Per-spawn stdio capture keyed by correlation ID for subprocess dispatch
date: 2026-04-29
category: architecture-patterns
module: Hive::Tui
problem_type: architecture_pattern
component: tooling
severity: medium
applies_when:
  - "Multiple background subprocesses share a single log file"
  - "Log rotation is bounded by a size cap that must hold as a real disk ceiling"
  - "Post-mortem diagnostics need to locate output from a specific spawn"
  - "Long-lived child fds can outlive a rename/rotation of the target file"
  - "Crashes or SIGKILL of the parent can orphan capture files"
tags:
  - tui
  - subprocess-dispatch
  - log-capture
  - correlation-id
  - log-rotation
  - diagnostics
  - lifecycle-cleanup
---

# Per-spawn stdio capture keyed by correlation ID for subprocess dispatch

## Context

A long-running TUI dispatches background subprocesses (workflow agents) and wants two things from them: (a) capture their stdio so a post-mortem diagnoser can show the user *why* the verb failed, and (b) keep the on-disk footprint bounded. The pre-fix `hive tui` aimed for both by redirecting every child's stdout and stderr into one shared appender file (`SUBPROCESS_LOG_PATH`), then rotating the file at every BEGIN/END marker stamp once it crossed `SUBPROCESS_LOG_MAX_BYTES`.

That shape failed in two compounding ways. First, the cap was not a real cap: a single child producing 50 MB of stderr between its BEGIN and END markers grew the shared file to 50+ MB before the next stamp could even check the size. Second, even when rotation did fire, an in-flight child still held a file descriptor pointing at the *renamed inode* (`<path>.1`) and kept writing there, while the diagnoser walked the freshly-recreated primary log and found nothing — the actual stderr was orphaned in `.1`. Concurrent verbs interleaved at line boundaries on top of that, so cross-talk diagnostics were a constant risk.

## Guidance

Don't share an appender across child lifetimes. Give every spawn its own capture file keyed by a correlation ID, and tie the file's lifetime to the reaper that owns the child.

Four ingredients make this pattern work:

1. **Per-spawn file keyed by a correlation ID.** Generate a short ID (8 hex chars is enough — ~4B distinct values, negligible collision risk over a rolling tail) at dispatch time. Embed the same ID in (a) the path of the per-spawn capture file (`<tmpdir>/<prefix>-<id>.log`) and (b) the BEGIN/END marker lines in the shared marker log. The marker log now carries only short structured records; the noisy child output never lands there.

2. **Redirect at spawn time, before the child exists.** Open the path with append-mode in the `Process.spawn` redirect dict (`out: [path, "a"], err: [path, "a"]`). The child's FD is bound to *this* file from the first byte of stdio — there is no shared inode to race against and no second writer.

3. **Lifecycle-bound cleanup in the reaper.** The same Thread that `wait2`s the child decides what happens to its capture: delete on `exit_code.zero?` (success has nothing to diagnose), keep on non-zero (the diagnoser needs it). Disk usage is now bounded by the rate of *failures*, not by the rate of total spawns.

4. **Opportunistic sweep at a hot point.** Crashed reapers, `kill -9` of the parent, and reboots leave orphan capture files behind that the success-path delete never runs against. Sweep the directory for files older than a generous cutoff (e.g. 24h) at every dispatch — `Dir.glob + N stat` is cheap enough to run inline and hot enough to keep the directory bounded under any realistic abuse.

The diagnoser then becomes a two-step lookup: parse the marker log tail to find the most recent `BEGIN[id]` for the verb of interest, then `read` the per-spawn capture at that ID. Keep a fallback for legacy or non-ID entries (interactive takeover, pre-rollout marker lines) so the read path stays robust.

## Why This Matters

The shared appender shape allowed two distinct failure modes that the per-spawn shape eliminates outright:

- **Cap busted by a single child.** Rotation that runs at marker checkpoints can't bound a file whose growth happens *between* checkpoints. One verbose child violated the documented `2 × MAX_BYTES` budget by an order of magnitude. Per-spawn redirect moves the noisy bytes out of the bounded log entirely; the marker log is now bounded for real because nothing but short marker lines is written to it.
- **FD-points-at-renamed-inode loses the diagnostic.** Unix `rename(2)` doesn't migrate open FDs to the new path. Any rotation strategy that involves an in-flight child's destination file will silently drop that child's later stderr into the rotated copy, where the diagnoser doesn't look. Per-spawn redirect makes the file private to one child, so rotation simply isn't a concern within its lifetime.

The wins compound: the correlation ID is free additional identity for cleanup, lookup, and concurrent-verb disambiguation; the marker log shrinks to one short line per BEGIN/END pair; concurrent agents stop cross-talking; and the disk-usage story finally matches the docstring.

## When to Apply

Reach for this pattern when **all** of the following hold:

- A long-running parent (TUI, daemon, supervisor) spawns child processes whose stdio it doesn't display live but wants to read post-mortem.
- Children may be **concurrent**, **detached**, **outlive the parent**, or be killed externally — i.e. the parent can't assume cooperative cleanup.
- Child output volume is **unbounded or operator-controlled** (verbose AI agents, build subprocesses, user-supplied commands), so any single shared file is a liability.
- A separate, structured marker / event log already exists or is desired for the parent's own observability.

If stdio is small, bounded, and synchronous — `Open3.capture3` returning to a single caller — you don't need this. The pattern is for the spawn-and-detach shape with later-read diagnosis.

## Examples

Pre-fix `spawn_background_child` — every child writes to one shared file:

```ruby
def spawn_background_child(argv)
  Process.spawn(*argv, pgroup: true,
    out: [SUBPROCESS_LOG_PATH, "a"],
    err: [SUBPROCESS_LOG_PATH, "a"])
end
```

Post-fix — per-spawn file keyed by the correlation ID generated in `dispatch_background`:

```ruby
def spawn_background_child(argv, spawn_id)
  path = spawn_capture_path(spawn_id)  # <tmpdir>/hive-tui-spawn-<id>.log
  Process.spawn(*argv, pgroup: true,
    out: [path, "a"],
    err: [path, "a"])
end
```

Reaper carrying lifecycle responsibility — delete on success, keep on failure:

```ruby
def spawn_reaper_thread(pid, verb, argv, dispatch, spawn_id = nil)
  Thread.new do
    _, status = Process.wait2(pid)
    exit_code = translate_status(status)
    stamp_subprocess_log("END exit=#{exit_code}", argv, id: spawn_id)
    delete_spawn_capture(spawn_id) if spawn_id && exit_code.zero?
    dispatch.call(Messages::SubprocessExited.new(verb: verb, exit_code: exit_code))
  end
end
```

Opportunistic sweep at the hot dispatch point — bounded by mtime, tolerant of `ENOENT`:

```ruby
SPAWN_CAPTURE_MAX_AGE_SECONDS = 24 * 60 * 60

def sweep_old_spawn_captures!
  cutoff = Time.now - SPAWN_CAPTURE_MAX_AGE_SECONDS
  Dir.glob(File.join(Dir.tmpdir, "hive-tui-spawn-*.log")).each do |path|
    File.delete(path) if File.mtime(path) < cutoff
  rescue Errno::ENOENT
    nil
  end
end
```

The cleanup-path tests in `test/integration/tui_subprocess_test.rb` exercise each leg of the pattern: `test_dispatch_background_writes_child_stderr_to_per_spawn_capture` (failure keeps the file), `test_successful_spawn_deletes_its_capture_file` (success drops it), `test_diagnose_recent_failure_reads_per_spawn_capture` (the diagnoser pairs marker ID → capture file), and `test_sweep_old_spawn_captures_deletes_orphans_past_cutoff` / `test_sweep_old_spawn_captures_keeps_recent_files` (the belt-and-suspenders sweep).

## Related

- [[architecture-patterns/background-spawn-and-signal-aware-marker-healing-2026-04-28]] — the dispatch-shape predecessor that introduced the BEGIN/END per-section structure this pattern formalizes per-spawn. Its "Subprocess log per-section structure" snippet describes the now-superseded shared-log model and is a candidate for refresh.
- `lib/hive/tui/subprocess.rb` — the implementation: `dispatch_background`, `spawn_background_child`, `spawn_reaper_thread`, `spawn_capture_path`, `delete_spawn_capture`, `sweep_old_spawn_captures!`, `recent_log_section_for`, `read_spawn_capture`.
- `wiki/commands/tui.md` — user-facing description of the dispatch surface and the shared marker log.
- GitHub issue #14 — *TUI: 64KB tail cap edge in `diagnose_recent_failure` under heavy concurrent stderr*. The per-spawn-capture pattern obviates the tail-cap edge case (the diagnoser reads one bounded per-spawn file, not a tail of an unbounded shared log).
- Commit `e030b24` on `feat/hive-tui` — the implementation of this pattern.
