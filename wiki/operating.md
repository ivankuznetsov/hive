---
title: Operating Hive
type: operating
source: lib/hive/commands/daemon.rb, lib/hive/commands/bot.rb, examples/systemd/, examples/launchd/
created: 2026-05-07
updated: 2026-05-15
tags: [operating, daemon, bot, systemd, launchd, install]
---

**TLDR**: Day-2 guide for running the hive daemon and Telegram bot.
Covers per-project daemon enrollment, bot token/allowlist setup,
autostart on macOS (launchd) and Linux (systemd), dry-run shakedowns,
log inspection, and how to disable automation mid-flight.

## Install

Hive v0.1.0 installs from pinned GitHub Release artifacts. All channels write
an `install-channel` marker so `hive update` delegates to the same channel
that installed the binary.

| Tier | Platforms | Status |
|------|-----------|--------|
| Tier 1 | macOS arm64, Ubuntu 22.04+ x86_64/aarch64, Arch Linux x86_64/aarch64 | Release tarballs and channel docs ship in v1 |
| Tier 2 | macOS x86_64, Debian 12+, Fedora 40+, WSL2 | Best effort through `install.sh`; no dedicated tap/AUR row |
| Tier 3 | Alpine/musl, NixOS, BSD | Unsupported; installer exits with a clear message |

Channels:

```bash
# macOS arm64
brew install ivankuznetsov/hive/hive

# Arch Linux
yay -S hive-bin

# glibc Linux fallback / Ubuntu 22.04+ (pin to the release tag, not main)
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/v0.1.0/install.sh -o "$tmpdir/hive-install.sh"
bash "$tmpdir/hive-install.sh"
```

`install.sh` accepts:

| Flag / env | Purpose |
|------------|---------|
| `--dry-run` | Resolve target + version + URLs and run the runtime preflight without downloading or writing anything. |
| `--prefix=<dir>` (or `HIVE_PREFIX=<dir>`) | Stage the versioned payload + `install-channel` marker under `<dir>/hive/…` instead of `${XDG_DATA_HOME}/hive`. `hive update` probes the prefix marker after the XDG marker, so subsequent updates re-use the same channel. |
| `--version=<tag>` (or `HIVE_VERSION=<tag>`) | Skip the GitHub API call and install a specific `vX.Y.Z` tag. |
| `HIVE_REPO_OWNER` / `HIVE_REPO_NAME` | Override the upstream owner/repo (for forks or mirror staging). Inputs are shape-validated. |
| `HIVE_BIN_OVERRIDE` (read by `hv` wrapper) | Point `hv` at a custom install path when Apache Hive shadows it. |

For an agent-assisted install, paste the repository-root `install.md` into
Claude Code, Codex, or Pi. It detects the host platform, chooses the channel,
verifies `hive --version`, offers `hive init`, and treats the skills package as
optional marketplace content.

Fresh installs use XDG locations:

| Purpose | Default |
|---------|---------|
| Config / registry | `~/.config/hive/config.yml` |
| Installed bash payloads and channel marker | `~/.local/share/hive/` |
| Daemon/bot runtime state and logs | `~/.local/state/hive/` |
| Cache | `~/.cache/hive/` |
| User binary symlink | `~/.local/bin/hive` |

`HIVE_HOME` remains a legacy/test override. Project state stays at
`<project>/.hive-state/`; install and uninstall do not move completed pipeline
work.

Apache Hive collision: the Homebrew formula installs an `hv` symlink and the
bash installer creates `hv` when another `hive` is already earlier on PATH. The
AUR package declares `conflicts=('hive' 'apache-hive')`, so pacman blocks the
collision before fallback aliasing is possible.

Updates and uninstall:

```bash
hive update --dry-run     # prints the would-be brew/yay/paru/bash command for the channel
                          # (the `dev` channel has no executable equivalent; it emits a
                          # `suggested action` line pointing at `git pull && bundle install`)
hive update               # delegates to the installing channel
hive uninstall            # removes registrations/config/cache, preserves work
hive uninstall --purge    # non-interactive; still preserves work
```

Skills package marketplace commands are documented for the optional companion
package. If the package is not published yet, Hive core install still succeeds:

| Agent | Command shape |
|-------|---------------|
| Claude Code | `claude plugin install ivankuznetsov/hive-skills` |
| Codex | `codex plugin install ivankuznetsov/hive-skills` |
| Pi | `pi install ivankuznetsov/hive-skills` |

## Prerequisites

Once per workstation:

- **`claude` CLI ≥ 2.1.118** on `PATH`. The daemon spawns the same
  `hive run` children as the interactive CLI; agent invocation is
  unchanged. Verify: `claude --version`.
- **`gh` authenticated.** The daemon's PR-merge watcher (ADR-024)
  polls `gh pr view --json state` to detect `MERGED` and auto-archive
  7-finalize → 8-done. Verify: `gh auth status`.
- **`/proc` mounted OR `ps` available.** The daemon refuses to start
  if it can't read its own `process_start_time` (PID-reuse defense).
  Verify: `ls /proc/$$ >/dev/null && echo OK` or `command -v ps`.
- **Telegram bot token** if using `hive bot`. Create the bot with
  BotFather, export `HIVE_TELEGRAM_BOT_TOKEN`, and add your numeric
  `chat_id` to `bot.chat_id_allowlist` in `~/.config/hive/config.yml`.

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

Inspect `~/.local/state/hive/logs/daemon.log` (one JSON document per line):

```bash
# What WOULD have been dispatched, by project
jq -r 'select(.event=="dispatched") | "\(.project)/\(.slug): \(.command)"' \
   ~/.local/state/hive/logs/daemon.log | sort -u

# Things skipped — the `reason` field tells you why
jq -r 'select(.event=="skipped") | "\(.project)/\(.slug): action=\(.action) reason=\(.reason // "—")"' \
   ~/.local/state/hive/logs/daemon.log | sort -u

# Anything blocked by caps (means at least one cap is too tight, or
# expected throttling under load)
jq -r 'select(.event=="blocked") | "\(.project)/\(.slug): \(.reason)"' \
   ~/.local/state/hive/logs/daemon.log | sort -u
```

Once the would-be dispatches look right, swap to live mode:

```bash
hive daemon stop
hive daemon start --detach
```

## Autostart

`hive init` writes the platform daemon unit for you (see ADR-024).
On Linux it lands at `~/.config/systemd/user/hive-daemon.service`; on
macOS at `~/Library/LaunchAgents/local.hive-daemon.plist`. The recipes
below are the manual fallback for environments where `hive init` could
not write the unit (read-only home, restricted user, custom layout) or
for migrating an existing install onto a newer template.

### Linux (systemd-user)

A sample unit ships at `examples/systemd/hive-daemon.service`. Install
manually only if `hive init` could not write it for you:

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

`hive init` writes the resolved plist at
`~/Library/LaunchAgents/local.hive-daemon.plist` with your real `hive`
binary path already substituted. The recipe below is the manual
fallback (uses the placeholder filename `hive-daemon.plist` so it can
sit alongside the auto-generated `local.hive-daemon.plist`); edit the
absolute paths first (replace `/Users/YOU/...` with your real paths —
`which hive` shows the binary), then:

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
own structured log (`~/.local/state/hive/logs/daemon.log`) is independent and
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

## Bot setup

The bot is global and uses the registry in `~/.config/hive/config.yml`.
Minimum config:

```yaml
bot:
  enabled: true
  chat_id_allowlist: [123456789]
```

Runtime token:

```bash
export HIVE_TELEGRAM_BOT_TOKEN=123456:token-from-botfather
hive bot start --dry-run
```

`--dry-run` is useful for first shakedown: inbound command parsing and
status notifications run, but state-changing child commands are not
spawned. The bot log is `~/.local/state/hive/logs/bot.log`:

```bash
jq -r '.event' ~/.local/state/hive/logs/bot.log | sort | uniq -c
```

Unauthorized chat IDs are logged once and receive no reply. Missing
token or empty allowlist exits 78 (`CONFIG`).

### Bot autostart

Linux sample unit:

```bash
mkdir -p ~/.config/systemd/user
cp examples/systemd/hive-bot.service ~/.config/systemd/user/
$EDITOR ~/.config/systemd/user/hive-bot.service   # set token / paths
systemctl --user daemon-reload
systemctl --user enable --now hive-bot
journalctl --user -u hive-bot -f
```

macOS sample plist:

```bash
mkdir -p ~/Library/LaunchAgents
cp examples/launchd/hive-bot.plist ~/Library/LaunchAgents/
$EDITOR ~/Library/LaunchAgents/hive-bot.plist     # set token / paths
launchctl load ~/Library/LaunchAgents/hive-bot.plist
```

The sample files run `hive bot start` in the foreground and let the
host supervisor restart on failure. `hive bot stop` remains the manual
drain path when you are not using systemd/launchd.

## Day-2 operations

| Need                                          | Command                                               |
|-----------------------------------------------|-------------------------------------------------------|
| Status + uptime                               | `hive daemon status` (`--json` for envelope)          |
| Follow the structured log                     | `hive daemon tail`                                    |
| Reload caps without restart                   | edit `~/.config/hive/config.yml` → `hive daemon reload` |
| Disable a project mid-flight                  | `hive daemon disable PROJECT` → `hive daemon reload`* |
| Enable a project mid-flight                   | `hive daemon enable PROJECT` → `hive daemon reload`*  |
| Drain + stop                                  | `hive daemon stop` (graceful TERM, ≤ `shutdown_grace_sec`) |
| Force-stop after a hang                       | `hive daemon stop` then check PID; the stop CLI escalates to KILL |
| Bot status / uptime                           | `hive bot status` (`--json` for envelope)          |
| Follow bot log                                | `hive bot tail`                                    |
| Reload bot allowlist / polling config         | edit `~/.config/hive/config.yml` → `hive bot reload` |
| Drain + stop bot                              | `hive bot stop`                                    |

\* `hive daemon reload` clears the per-tick enable cache, but the
cache is also cleared at the start of every tick (PR-40 follow-up
#2), so within one `poll_interval_sec` the toggle takes effect on
its own. Reload is just for instant pickup.

**Bot shutdown latency**: `hive bot stop` sends `SIGTERM` and waits up to
`shutdown_grace_sec` (default 60) for in-flight children before
escalating to `SIGKILL`. The supervisor's signal-reaction wakeup is
clamped to half-second slices; expect up to ~0.5s of slop between
`SIGTERM` arriving and the worker threads observing `@shutdown`. This
is an intentional latency/safety trade — the half-second granularity
keeps the polling threads from busy-spinning while still letting
`hive bot stop` return inside its grace window for any well-behaved
child.

## Tuning concurrency

Defaults in `Config::DEFAULTS["daemon"]`:

| Knob                            | Default | Notes                                                       |
|---------------------------------|---------|-------------------------------------------------------------|
| `max_concurrent_runs`           | 5       | Global cap. Raise carefully — multiplies cost ceiling.      |
| `max_concurrent_per_project`    | 5       | Per-project burst cap. Lower it below the global cap to force cross-project sharing. |
| `max_runs_per_day_per_project`  | 50      | Circuit-breaker. Raise if a project legitimately needs it.  |
| `poll_interval_sec`             | 30      | Tick cadence. ≥ 5 enforced.                                 |
| `edit_debounce_sec`             | 30      | Mid-save grace for `needs_input` rows. 0 disables.          |
| `pr_merge_poll_interval_sec`    | 300     | `gh pr view` cadence per task. ≥ 60 enforced (rate limits). |
| `transient_retry_backoff_sec`   | 60      | Reserved (current backoff schedule is hardcoded).           |
| `shutdown_grace_sec`            | 600     | TERM→KILL window for `hive daemon stop`.                    |
| `log_max_bytes`                 | 10 MB   | Rotation threshold.                                         |
| `log_max_files`                 | 5       | 5 × 10 MB = 50 MB log budget.                               |

To override, edit `~/.config/hive/config.yml`:

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
Check `~/.local/state/hive/.daemon.pid`. If it's missing, the daemon failed
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
- [[commands/bot]] · [[modules/bot]]
- [[decisions]] (ADR-024, ADR-026) · [[active-areas]]
- [[architecture]] · [[cli]]
