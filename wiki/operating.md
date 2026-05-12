---
title: Operating Hive
type: operating
source: lib/hive/commands/daemon.rb, examples/systemd/, examples/launchd/
created: 2026-05-07
updated: 2026-05-08
tags: [operating, daemon, systemd, launchd, install]
---

**TLDR**: Day-2 guide for running the hive daemon. Covers per-project
enrollment, autostart on macOS (launchd) and Linux (systemd), the
mandatory `--dry-run` shakedown, log inspection, and how to disable
projects mid-flight.

## Prerequisites

Once per workstation:

- **`claude` CLI ≥ 2.1.118** on `PATH`. The daemon spawns the same
  `hive run` children as the interactive CLI; agent invocation is
  unchanged. Verify: `claude --version`.
- **`gh` authenticated.** The daemon's PR-merge watcher (ADR-024)
  polls `gh pr view --json state` to detect `MERGED` and auto-archive
  6-pr → 7-done. Verify: `gh auth status`.
- **`/proc` mounted OR `ps` available.** The daemon refuses to start
  if it can't read its own `process_start_time` (PID-reuse defense).
  Verify: `ls /proc/$$ >/dev/null && echo OK` or `command -v ps`.

## Enrolling existing projects

Projects initialised before ADR-024 don't have a `daemon:` block in
`<project>/.hive-state/config.yml`. By design they fall back to
`daemon.enabled: false` (see ADR-023's no-silent-legacy-flip pattern,
ADR-024 §"Decision"), so the daemon will not touch them until you opt
in. Two ways:

```bash
# Single project (matches the registered project name)
hive daemon enable writero

# Every registered project at once
hive daemon enable --all

# Inverse
hive daemon disable writero
hive daemon disable --all
```

The command edits the project's `.hive-state/config.yml` atomically
(tempfile + rename), preserving every other key. Pre-existing daemon
tunables (`poll_interval_sec`, `max_concurrent_runs`, …) survive — the
toggle only flips `enabled`.

For new projects, `hive init` asks at the TTY prompt and defaults to Y
— no separate enable step.

## First run: the mandatory `--dry-run` shakedown

The daemon's worst-case in-flight cost ceiling is
`max_concurrent_runs × per-task budget cap` from ADR-023, which works
out to ~$4425 at default caps. Before letting it spawn real children,
run it in dry-run for ~24 hours:

```bash
hive daemon start --dry-run --detach
hive daemon status                  # verify running
hive daemon tail                    # ctrl-C to leave; daemon keeps running
```

Inspect `~/Dev/hive/logs/daemon.log` (one JSON document per line):

```bash
# What WOULD have been dispatched, by project
jq -r 'select(.event=="dispatched") | "\(.project)/\(.slug): \(.command)"' \
   ~/Dev/hive/logs/daemon.log | sort -u

# Things skipped — the `reason` field tells you why
jq -r 'select(.event=="skipped") | "\(.project)/\(.slug): action=\(.action) reason=\(.reason // "—")"' \
   ~/Dev/hive/logs/daemon.log | sort -u

# Anything blocked by caps (means at least one cap is too tight, or
# expected throttling under load)
jq -r 'select(.event=="blocked") | "\(.project)/\(.slug): \(.reason)"' \
   ~/Dev/hive/logs/daemon.log | sort -u
```

Once the would-be dispatches look right, swap to live mode:

```bash
hive daemon stop
hive daemon start --detach
```

## Autostart

### Linux (systemd-user)

A sample unit ships at `examples/systemd/hive-daemon.service`. Install:

```bash
mkdir -p ~/.config/systemd/user
cp examples/systemd/hive-daemon.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now hive-daemon
journalctl --user -u hive-daemon -f
```

If you log out and want the daemon to keep running:

```bash
sudo loginctl enable-linger $USER
```

The unit declares `Type=simple` and runs `hive daemon start` in the
foreground — systemd is the supervisor. `Restart=on-failure` brings
the daemon back after a crash; the daemon's own SIGTERM handler does
the graceful drain (`daemon.shutdown_grace_sec`, default 600 s).

The shipped unit hardcodes `TimeoutStopSec=900` (15 min — drain budget
plus headroom). If you raise `daemon.shutdown_grace_sec` above 900,
**also** raise `TimeoutStopSec=` in your installed unit to match
(`shutdown_grace_sec + 300` is a reasonable cushion). Otherwise
systemd will SIGKILL still-running stage children mid-`hive run`,
losing in-flight work.

If `hive` lives behind a version manager (rbenv / asdf / mise), edit
the `ExecStart=` line to use the shim's absolute path — systemd-user
doesn't load your shell's rc files.

### macOS (launchd)

A sample plist ships at `examples/launchd/hive-daemon.plist`.
Edit the absolute paths first (replace `/Users/YOU/...` with your
real paths — `which hive` shows the binary), then:

```bash
mkdir -p ~/Library/LaunchAgents
cp examples/launchd/hive-daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/hive-daemon.plist
```

Stop / restart:

```bash
launchctl unload ~/Library/LaunchAgents/hive-daemon.plist
launchctl load   ~/Library/LaunchAgents/hive-daemon.plist
```

launchd captures stdout/stderr to the paths declared in the plist
(`~/Library/Logs/hive-daemon.{out,err}.log` by default). The daemon's
own structured log (`~/Dev/hive/logs/daemon.log`) is independent and
preferred for parsing — the launchd capture is mostly empty.

`KeepAlive` with `SuccessfulExit: false` means launchd respawns on
crash but not after a clean `hive daemon stop`. `ThrottleInterval: 30`
is the floor between respawn attempts.

The plist's `ProgramArguments` wraps the invocation in a tiny
`/bin/sh -c '[ -x "$0" ] || exit 0; exec "$0" "$@"'` precheck —
launchd has no native equivalent of systemd's `StartLimitBurst`, so
without this wrapper a wrong binary path would respawn every 30 s
forever (filling `hive-daemon.err.log` with `command not found`). The
wrapper turns "binary missing or not executable" into a clean exit 0,
which `KeepAlive { SuccessfulExit: false }` then respects (no respawn).
A real daemon crash still exits non-zero through `exec` and respawns
normally. If you customise `ProgramArguments`, keep the precheck.

## Day-2 operations

| Need                                          | Command                                               |
|-----------------------------------------------|-------------------------------------------------------|
| Status + uptime                               | `hive daemon status` (`--json` for envelope)          |
| Follow the structured log                     | `hive daemon tail`                                    |
| Reload caps without restart                   | edit `~/Dev/hive/config.yml` → `hive daemon reload`   |
| Disable a project mid-flight                  | `hive daemon disable PROJECT` → `hive daemon reload`* |
| Enable a project mid-flight                   | `hive daemon enable PROJECT` → `hive daemon reload`*  |
| Drain + stop                                  | `hive daemon stop` (graceful TERM, ≤ `shutdown_grace_sec`) |
| Force-stop after a hang                       | `hive daemon stop` then check PID; the stop CLI escalates to KILL |

\* `hive daemon reload` clears the per-tick enable cache, but the
cache is also cleared at the start of every tick (PR-40 follow-up
#2), so within one `poll_interval_sec` the toggle takes effect on
its own. Reload is just for instant pickup.

## Tuning concurrency

Defaults in `Config::DEFAULTS["daemon"]`:

| Knob                            | Default | Notes                                                       |
|---------------------------------|---------|-------------------------------------------------------------|
| `max_concurrent_runs`           | 3       | Global cap. Raise carefully — multiplies cost ceiling.      |
| `max_concurrent_per_project`    | 1       | Bump to 2 if you want two-track per project.                |
| `max_runs_per_day_per_project`  | 50      | Circuit-breaker. Raise if a project legitimately needs it.  |
| `poll_interval_sec`             | 30      | Tick cadence. ≥ 5 enforced.                                 |
| `edit_debounce_sec`             | 30      | Mid-save grace for `needs_input` rows. 0 disables.          |
| `pr_merge_poll_interval_sec`    | 300     | `gh pr view` cadence per task. ≥ 60 enforced (rate limits). |
| `transient_retry_backoff_sec`   | 60      | Reserved (current backoff schedule is hardcoded).           |
| `shutdown_grace_sec`            | 600     | TERM→KILL window for `hive daemon stop`.                    |
| `log_max_bytes`                 | 10 MB   | Rotation threshold.                                         |
| `log_max_files`                 | 5       | 5 × 10 MB = 50 MB log budget.                               |

To override, edit `~/Dev/hive/config.yml`:

```yaml
registered_projects:
  # ... existing entries ...

daemon:
  max_concurrent_runs: 5
  max_concurrent_per_project: 2
  poll_interval_sec: 60
```

`hive daemon reload` (or restart) picks up the new values.

## Cost-runaway response

If `daemon.log` shows unexpected dispatch volume:

```bash
hive daemon stop                          # immediate halt
hive daemon disable --all                 # belt-and-suspenders
# investigate (jq filters above)
hive daemon start --dry-run --detach      # re-shakedown
```

The per-task `.lock` (ADR-007) is the last-resort safety net; the
daemon's caps are upstream of it and are what actually prevent fan-out.

## Troubleshooting

**`hive daemon start` exits with "cannot read process start time".**
This is C5's refuse-to-start guard. Either `/proc` is hidden (some
container hardenings set `hidepid=2`) or `ps` is missing (distroless
images). Mount `/proc`, install `procps`, or run the daemon in an
environment where one of the two is reachable.

**`hive daemon status` says "not running" but I just started it.**
Check `~/Dev/hive/.daemon.pid`. If it's missing, the daemon failed
during startup — check `journalctl --user -u hive-daemon` (Linux) or
the launchd `~/Library/Logs/hive-daemon.err.log` (macOS) for the
crash reason.

**The daemon ran my project but didn't auto-archive after I merged.**
The PR-merge watcher polls every `pr_merge_poll_interval_sec`
(default 5 min). If `gh auth` lapsed, the watcher logs `:gh_error`
and after 5 consecutive failures drops the entry. Re-authenticate
with `gh auth login`, then either restart the daemon or run the
archive manually: `hive archive <slug>`.

**A project I disabled is still being dispatched.**
The per-tick cache invalidation lands within one `poll_interval_sec`
without operator action; if it's been longer than that, the YAML
edit didn't land where the daemon reads from. Check
`<project>/.hive-state/config.yml` actually shows
`daemon: { enabled: false }` — `hive daemon disable PROJECT` is the
safest path.

## Backlinks

- [[commands/daemon]] · [[modules/daemon]]
- [[decisions]] (ADR-024) · [[active-areas]]
- [[architecture]] · [[cli]]
