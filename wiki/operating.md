---
title: Operating Hive
type: operating
source: README.md, bin/hv, install.sh, lib/hive/commands/daemon.rb, lib/hive/commands/babysit.rb, lib/hive/commands/bot.rb, examples/systemd/, examples/launchd/, openclaw/skills/hive/SKILL.md, openclaw/README.md
created: 2026-05-07
updated: 2026-06-07
tags: [operating, daemon, bot, systemd, launchd, install]
---

**TLDR**: Day-2 guide for running the hive daemon, experimental PR babysitter, and Telegram bot.
Covers install-time daemon autostart, per-project daemon/babysitter enrollment, bot token/allowlist setup,
autostart on macOS (launchd) and Linux (systemd), dry-run shakedowns,
log inspection, community support, and how to disable automation mid-flight.

## Worktree-first workflow

All new feature, bugfix, or refactor work on `hive` itself starts in
an isolated git worktree — never the main checkout. Two paths:

- **Delegated tasks (recommended for agents):** invoke the `Agent`
  tool with `isolation: "worktree"`. The harness creates a scratch
  worktree, runs the task, and only persists changes when the agent
  produced a diff.
- **Direct work:** `git worktree add ../hive-feature-name <branch>`,
  do the work there, then push/PR from the worktree.

The main checkout (`~/Dev/hive/`) stays clean so parallel reviews,
spot checks, and the LLM-maintained `wiki/` index reflect a stable
HEAD. Don't mutate it for non-trivial changes. The policy is
codified in `CLAUDE.md`'s `## Workflow` section.

## Install

Hive ships as the `hive-cli` rubygem attached to each GitHub Release,
signed with cosign keyless attestation. All channels download the same `.gem`,
verify the signature, run `gem install` against it, and write an
`install-channel` marker so `hive update` delegates back to the same channel.
Runtime deps (bubbletea, lipgloss, thor, telegram-bot-ruby) come from
rubygems.org with precompiled platform binaries. The managed llm-wiki indexer,
QMD, is installed separately through npm into Hive's data prefix when npm is
available; Hive does not auto-install Node.js/npm itself.

| Tier | Platforms | Status |
|------|-----------|--------|
| Tier 1 | macOS arm64, Ubuntu 22.04+ x86_64/aarch64, Arch Linux x86_64/aarch64 | Homebrew, `install.sh`, and AUR (`hive-bin`) are documented install channels |
| Tier 2 | Debian 12+, Fedora 40+, WSL2 | Best effort through `install.sh`; no dedicated tap/AUR row |
| Tier 3 | macOS x86_64 for `install.sh`, Alpine/musl, NixOS, BSD | Unsupported; installer exits with a clear message |

Channels:

```bash
# macOS arm64
brew install ivankuznetsov/hive/hive

# Arch Linux
yay -S hive-bin

# glibc Linux fallback / Ubuntu 22.04+ (pin to the release tag, not main)
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/v0.2.0/install.sh -o "$tmpdir/hive-install.sh"
bash "$tmpdir/hive-install.sh"
```

`install.sh` accepts:

| Flag / env | Purpose |
|------------|---------|
| `--dry-run` | Resolve target + version + URLs and run the runtime preflight without downloading or writing anything. |
| `--prefix=<dir>` (or `HIVE_PREFIX=<dir>`) | Stage the versioned payload + prefix marker under `<dir>/hive/…` and mirror `install-channel`/`install-prefix` under `${XDG_DATA_HOME}/hive`, so `hive update` can re-use the prefix without re-exporting `HIVE_PREFIX`. |
| `--version=<tag>` (or `HIVE_VERSION=<tag>`) | Skip the GitHub API call and install a specific `vX.Y.Z` tag. |
| `HIVE_REPO_OWNER` / `HIVE_REPO_NAME` | Override the upstream owner/repo (for forks or mirror staging). Inputs are shape-validated. |
| `HIVE_BIN_OVERRIDE` (read by `hv` wrapper) | Point `hv` at a custom install path when Apache Hive shadows it. |
| `HIVE_INSTALL_QMD=0` | Skip the managed QMD install step. Use only when npm is unavailable or a host policy forbids npm package installs. |
| `HIVE_QMD_NPM_PACKAGE` | Override the npm package spec used for QMD install; defaults to `@tobilu/qmd`. |
| `HIVE_QMD_BIN` | Runtime override read by generated wiki scripts and `hive doctor`; points at an executable `qmd` when PATH or the managed install path is not enough. |

For an agent-assisted install, paste the repository-root `install.md` into
Claude Code, Codex, or Pi. It detects the host platform, chooses the channel,
installs or repairs the QMD wiki indexer when npm is available, verifies
`hive --version`, runs `hive daemon install --json` so the per-user daemon
service is installed/enabled by default, offers `hive init`, and treats the
skills package as optional marketplace content.

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

Apache Hive collision: the Homebrew formula installs an `hv` symlink. The bash
installer always writes a working `${data_home}/gems/bin/hv` wrapper that
delegates to its GEM_HOME-aware `hive` wrapper, and exposes it under the user
bin directory when another `hive` is already earlier on PATH or when it is
refreshing an existing owned symlink. The in-tree `bin/hv` fallback probes only
`HIVE_BIN_OVERRIDE`,
`${XDG_BIN_HOME:-$HOME/.local/bin}/hive`, `${HOMEBREW_PREFIX:-/opt/homebrew}/bin/hive`,
and `/usr/local/bin/hive`; it intentionally does not fall through to
`/usr/bin/hive` or `/opt/hive/bin/hive`, because those are common Apache Hive
locations. Use `HIVE_BIN_OVERRIDE` for a custom Hive CLI install path. RubyGems
does not advertise `hv` as a gem executable, because RubyGems would wrap the
bash launcher in a Ruby binstub; install channels create the working `hv`
wrapper/symlink themselves. The AUR package also uses an `hv -> hive` symlink;
its `conflicts=('hive' 'apache-hive')` metadata blocks the parallel install
before fallback aliasing is possible.

Daemon autostart is part of install, not project enrollment. The bash installer
runs `hive daemon install --json` after installing the gem. Agent-assisted
Homebrew/AUR/manual installs run the same command after `hive --version`
verification. If systemd-user or launchd cannot actually enable/start the unit,
`hive daemon install --json` returns a failed envelope while leaving the written
unit on disk for manual repair. Manual package users should run
`hive daemon install` once after install if they did not use the agent prompt;
package hooks cannot reliably start a per-user systemd/launchd service for every
host setup.

Updates and uninstall:

```bash
hive update --dry-run     # prints the would-be brew/yay/paru/bash command for the channel
                          # (the `dev` channel has no executable equivalent; it emits a
                          # `suggested action` line pointing at `git pull && bundle install`)
hive update               # delegates to the installing channel
hive uninstall            # removes registrations/config/cache, preserves work
hive uninstall --purge    # non-interactive; still preserves work
hive uninstall --force-purge-state
                          # destructive: removes accumulated hive state and
                          # registered project .hive-state directories
```

Skills package marketplace commands are documented for the optional companion
package, but the package is still a separate external publishing follow-up.
Do not run these commands until `ivankuznetsov/hive-skills` is published; Hive
core install still succeeds without it:

| Agent | Command shape |
|-------|---------------|
| Claude Code | `claude plugin install ivankuznetsov/hive-skills` |
| Codex | `codex plugin install ivankuznetsov/hive-skills` |
| Pi | `pi install ivankuznetsov/hive-skills` |

OpenClaw support now lives in-tree under `openclaw/skills/hive/`. It is one
skill, not a TypeScript plugin and not a multi-listing bundle: the ClawHub slug
is `hive-cli`, the public listing is
`https://clawhub.ai/ivankuznetsov/hive-cli`, and the installed slash command is
`/hive`. The checked-in skill is version `0.1.1`. ClawHub uses the skill
frontmatter `description` as the public page summary and search text, so listing
copy belongs in that field and in the opening `SKILL.md` body for the single
umbrella skill. `/hive setup` guides confirmed Hive install, strict `hive`/`hv`
version verification, `hive daemon install`, and optional non-interactive
`hive init`; after setup, users pass normal CLI verbs as
`/hive status --json`, `/hive plan <slug>`, `/hive develop <slug>`, and so on.
The skill also documents `/hive wiki compile-log --check` as the read-only
aggregate-changelog verification path and tells agents to reserve mutating
`hive wiki compile-log` runs for merge/rebase cleanup or explicit user requests.
The naked `hive` ClawHub slug is already owned by another publisher, so it is
intentionally not used.

## Community

The public Hive Discord group is `https://discord.gg/Qg5E7rMt`. Keep the
GitHub README link pointed at that invite unless a newer canonical community
URL is announced.

## Release verification

The release ceremony exercises the published artifact end-to-end via
[`packaging/verify-release.sh`](../packaging/verify-release.sh). The
script installs a published release into an isolated XDG/HIVE_HOME/HOME
tmp prefix, walks the command surface (`hive --version`, `hive doctor`,
`hive init`, `hive new`, `hive status --json`, `hive daemon install
[--force] --json`, `hive uninstall`), validates JSON envelopes against
the published schemas, and asserts no state leaks outside the prefix.

Local usage:

```bash
packaging/verify-release.sh --version=v0.2.0
packaging/verify-release.sh --version=v0.2.0 --report=json | jq .ok
```

Exit codes:

- `0` — all verifications passed; tmp prefix removed
- `1` — a verification step failed; tmp prefix preserved at the
  path printed in the trailing `[verify] logs preserved at` line
- `2` — bad arguments
- `3` — prerequisite missing (`curl`, `ruby`, `jq`, `git`)

`--report=json` emits a single `hive-verify-release.v1` envelope on
stdout (with human prose redirected to stderr) for programmatic
consumption: `{schema, schema_version, ok, version, prefix, passed,
failed, steps[]}` where each step is `{name, passed, failed}`.

In CI, the `verify-release` job in
[`.github/workflows/install-smoke.yml`](../.github/workflows/install-smoke.yml)
runs this script against the pinned `HIVE_VERSION` whenever the
matching GitHub Release exists. The script feature-detects
post-pin subcommands (e.g., `daemon install` shipped in PR #113) and
gracefully skips assertions the released binary doesn't support — so
the script keeps providing value during the gap between when a feature
lands on main and when the next release tag is cut.

## Prerequisites

Once per workstation:

- **`claude` CLI ≥ 2.1.118** on `PATH`. The daemon spawns the same
  `hive run` children as the interactive CLI; agent invocation is
  unchanged. Verify: `claude --version`.
- **`gh` authenticated.** The daemon's PR-merge watcher (ADR-024)
  polls `gh pr view --json state` to detect `MERGED` and auto-archive
  8-finalize → 9-done. Verify: `gh auth status`.
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
— no separate project-enable step. This prompt is project enrollment only; the
daemon service should already be installed and enabled globally.

## Experimental PR babysitter

The babysitter is a separate daemon from `hive daemon`. It does not
advance task folders; it walks open GitHub PRs for projects with
`babysitter.enabled: true` and asks the configured development agent to
repair conflicts or red CI in `.hive-state/babysitter/worktrees/<pr>/`.

Fresh `hive init` prompts for `babysitter.enabled` and defaults to Y.
Existing projects can opt in by adding or editing this block in
`<project>/.hive-state/config.yml`:

```yaml
babysitter:
  enabled: true
  interval: 10m
  max_concurrent_prs: 2
  labels_ignore: [wip, do-not-merge, draft]
  dry_run: false
  budget_minutes: 30
  budget_usd: 50
```

Run a read-only shakedown before live use:

```bash
hive babysit --once PROJECT --dry-run
hive babysit start --dry-run --detach
hive babysit tail
```

Inspect `<project>/.hive-state/babysitter/events.jsonl`,
`<project>/.hive-state/babysitter/status.md`, and any
`.babysitter-dry-run-plan.md` files under the PR worktrees. When the
results look right, stop the dry-run process and start live mode:

```bash
hive babysit restart --detach
```

`hive babysit reload` refreshes config/log settings only; the detached
Ruby process keeps the source code it loaded at start. After pulling a
new checkout or upgrading Hive, run `hive babysit status` and restart if
it reports that the process predates the current source checkout.

Kill switch: set `babysitter.enabled: false`; the dispatcher reloads
project config each tick. v1 has no launchd/systemd install command for
the babysitter.

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

`hive daemon install` writes and enables the platform daemon unit (see
ADR-024). On Linux it lands at `~/.config/systemd/user/hive-daemon.service`;
on macOS at `~/Library/LaunchAgents/local.hive-daemon.plist`. Installers and
agent-assisted setup run this by default. `hive init` also idempotently ensures
the service after project setup, but the init prompt only controls whether that
project is enrolled for dispatch. The recipes below are the manual fallback for
environments where the installer could not write or enable the unit (read-only
home, restricted user, custom layout) or for migrating an existing install onto
a newer template.

### Linux (systemd-user)

A sample unit ships at `examples/systemd/hive-daemon.service`. Install
manually only if `hive daemon install` could not write it for you:

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

`hive daemon install` writes the resolved plist at
`~/Library/LaunchAgents/local.hive-daemon.plist` with your real `hive`
binary path already substituted. Homebrew installs use the stable
`${HOMEBREW_PREFIX}/bin/hive` symlink so `brew upgrade hive` keeps the daemon
path current. The recipe below is the manual
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
hive bot status
```

`hive bot start` backgrounds by default so the shell prompt returns immediately. `--dry-run` is useful for first shakedown: inbound command parsing and status notifications run, but state-changing child commands are not spawned. Use `hive bot start --foreground --dry-run` when you want to watch the process under a terminal or process supervisor. The bot log is `~/.local/state/hive/logs/bot.log`:

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

The sample files run `hive bot start --foreground` and let the
host supervisor restart on failure. Plain `hive bot start` backgrounds
for manual use. `hive bot stop` remains the manual
drain path when you are not using systemd/launchd.

## Day-2 operations

| Need                                          | Command                                               |
|-----------------------------------------------|-------------------------------------------------------|
| Status + uptime                               | `hive daemon status` (`--json` for envelope)          |
| Follow the structured log                     | `hive daemon tail`                                    |
| Reload caps without restart                   | edit `~/.config/hive/config.yml` → `hive daemon reload` |
| Disable a project mid-flight                  | `hive daemon disable PROJECT` → `hive daemon reload`* |
| Enable a project mid-flight                   | `hive daemon enable PROJECT` → `hive daemon reload`*  |
| Take over a stuck task manually               | `hive tui`, focus the row, press `s`                  |
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
| `max_concurrent_runs`           | 3       | Global cap. Raise carefully — multiplies cost ceiling.      |
| `max_concurrent_per_project`    | 3       | Per-project burst cap. Lower it below the global cap to force cross-project sharing. |
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
  max_concurrent_runs: 3
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

**A task is stuck but you want to finish it yourself.**
Open `hive tui`, focus the row, and press `s`. Hive marks the task
`MANUAL_STEERING` so `hive run` and the daemon skip it, opens the
configured development agent in the feature worktree with the slug's
stage folders preloaded, then archives the stage folder under
`.hive-state/stages/archived-manual/` when the agent exits.

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
