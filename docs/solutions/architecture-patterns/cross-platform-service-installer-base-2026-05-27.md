---
title: Cross-platform service installer — template-method base, launchd crash-loop circuit breaker, warn-and-continue teardown
date: 2026-05-27
category: architecture-patterns
module: hive
problem_type: architecture_pattern
component: tooling
severity: medium
applies_when:
  - "adding a new per-user autostart service (systemd unit / launchd plist) to the hive CLI"
  - "writing a launchd KeepAlive plist for a service that can crash on startup"
  - "parsing a YAML-payload pid file during uninstall or shutdown"
  - "rewriting an already-loaded launchd plist or already-running systemd unit on upgrade"
related_components:
  - lib/hive/commands/service_installer/base.rb
  - lib/hive/commands/daemon/service_installer.rb
  - lib/hive/commands/bot/service_installer.rb
  - lib/hive/commands/uninstall.rb
tags:
  - service-installer
  - template-method
  - systemd
  - launchd
  - cross-platform
  - crash-loop
  - atomic-write
  - cli
---

# Cross-platform service installer — template-method base, launchd crash-loop circuit breaker, warn-and-continue teardown

## Context

Hive ships two per-user autostart services: the orchestration `daemon` and the Telegram `bot`. Each can be installed as a native init unit (systemd-user on Linux, launchd on macOS) via `hive daemon install` / `hive bot install`. The install lifecycle is non-trivial: it must detect drift against a user-edited unit, back up before overwriting, write atomically, enable/load through the right service manager, bake a correct `PATH` so a version-managed Ruby resolves, and report a precise outcome and exit code. Doing this twice — once per service — invited copy-paste divergence.

The bot-autostart work (PR #195) factored that lifecycle into `Hive::Commands::ServiceInstaller::Base`, a template-method abstract class, with `Daemon::ServiceInstaller` and `Bot::ServiceInstaller` as thin subclasses. The base was extracted **first**, before any bot code was written — the commit was validated as byte-identical (the existing daemon installer test passed unchanged, plus a side-by-side render+messages diff) so the refactor carried zero behavioral drift for the daemon (session history). The bot installer was then added as a subclass. Along the way two cross-platform gotchas were nailed down: a macOS-specific respawn-loop circuit breaker, and a corrupt-pid teardown rule. This doc captures all three so the next platform installer (a Windows service, an OpenRC unit, a second daemon) can be added by overriding hooks rather than re-deriving the mechanics.

The work was deliberately sequenced **after** PR #189 (which made daemon autostart the default during `hive daemon install` and heavily modified `daemon/service_installer.rb` — binary resolution, `HIVE_INVOKED_BIN`). Starting the base extraction before #189 landed would have conflicted in the shared installer file (session history).

Source files:
- `lib/hive/commands/service_installer/base.rb`
- `lib/hive/commands/daemon/service_installer.rb`
- `lib/hive/commands/bot/service_installer.rb`
- `lib/hive/commands/uninstall.rb`
- `examples/launchd/hive-bot.plist`, `examples/systemd/hive-bot.service`

## Guidance

### 1. Put the install lifecycle in a template-method base; subclasses override only identity + rendering

`ServiceInstaller::Base` owns everything platform-agnostic:

- **Drift detection** — `write_if_safe` compares the on-disk unit to the freshly rendered template; identical → `:unchanged`, differs without `--force` → `:drifted` (leaves the user's hand-edit untouched).
- **Timestamped backup** — on `--force`, the previous file is copied to `<path>.bak-<UTC-timestamp>` before overwrite.
- **Atomic write** — `atomic_write` writes a tempfile in the target dir then `File.rename`s, so no torn-write window.
- **Outcome enum** — `:written`, `:upgraded`, `:unchanged`, `:drifted`, `:failed`, `:autostart_unavailable`, `:unsupported`. The `:autostart_unavailable` case (systemd-user missing, e.g. WSL/minimal containers) is deliberately distinct from `:failed` so the caller still exits 0.
- **Ruby-shim PATH detection** — maps mise/rbenv/asdf install roots to shim dirs; `build_path_line` prepends the matching shim so `#!/usr/bin/env ruby` in `bin/hive` resolves to a Ruby that has the gem's deps.
- **Read-only probe** — `service_state` / `service_enabled?` query install state without writing, enabling, or loading anything (used by `hive bot status` / `hive daemon status` `--json`).

Subclasses override only these hooks — the base `raise NotImplementedError` on the required ones so a missing override fails loudly:

```ruby
def service_name; raise NotImplementedError, "#{self.class} must define #service_name"; end
def cli_label;    raise NotImplementedError, "#{self.class} must define #cli_label";    end
def service_noun; raise NotImplementedError, "#{self.class} must define #service_noun"; end
def unit_noun;    raise NotImplementedError, "#{self.class} must define #unit_noun";    end
def target_path;  raise NotImplementedError, "#{self.class} must define #target_path";  end
def render_systemd; raise NotImplementedError, "#{self.class} must define #render_systemd"; end
def render_launchd; raise NotImplementedError, "#{self.class} must define #render_launchd"; end

# Optional — defaults provided in the base:
def upgrade_restart_warning; nil; end   # nil = no long stop-drain to warn about
def launchd_label; "local.#{service_name}"; end
```

The entire `Bot::ServiceInstaller` is then identity + two `render_*` methods. The two services differ in exactly two meaningful ways:

1. **ExecStart ownership.** The daemon double-daemonizes via its own runtime (`ExecStart=... daemon start`). The bot runs `ExecStart=... bot start --foreground` so systemd/launchd owns the process lifecycle directly. The bot also needs **no inline secret** — it loads `~/.config/hive/.env` on start via `Hive::EnvFile`, so the token never goes in the unit.
2. **Stop-drain warning.** The daemon has `TimeoutStopSec=900` to let in-flight children drain, so a force-upgrade restart can block ~15 min — it overrides `upgrade_restart_warning` with a 900s warning. The bot has no child drain, so it inherits the base's `nil` (no warning).

### 2. On launchd, KeepAlive must be `SuccessfulExit: false`, never unconditional `true`

systemd-user caps respawns with `StartLimitBurst` / `StartLimitIntervalSec`, so a crash-looping unit eventually lands in `failed`. launchd has **no global respawn cap**. An unconditional `KeepAlive <true/>` will busy-loop a crashing process forever — concretely, a bot that crashes on an expired Telegram token would peg a CPU respawning every `ThrottleInterval`.

Use `KeepAlive { SuccessfulExit: false }`: restart only on unclean (non-zero) exit, leave a clean exit stopped. Pair it with a `/bin/sh` precheck in `ProgramArguments` that converts "binary missing/not executable" into a clean `exit 0` — so a wrong path stops the loop after one attempt, while a real crash still respawns. There is a subtle interaction: the `[ -x "$0" ] || exit 0` precheck only acts as a circuit breaker *because* KeepAlive is `SuccessfulExit: false`. Under unconditional `<true/>`, that same clean `exit 0` is itself respawned, turning the precheck into a 30-second busy loop that also defeats `hive bot stop` (session history).

### 3. Teardown reads of a pid file must guard the type and warn-and-continue

`uninstall.rb` is a destructive multi-step operation (deregister daemon → deregister bot → wipe config/cache → remove data → clean project state). Any unrescued exception mid-sequence leaves the system half-uninstalled. The bot's `.bot.pid` is a YAML Hash (`{pid:, started_at:}`), unlike the daemon's bare-integer `.daemon.pid`. A corrupt or legacy bare-scalar `.bot.pid` (e.g. `"12345"`) is **still valid YAML** — `YAML.safe_load` returns an `Integer`, and `Integer#[]` raises `TypeError`, which previously aborted the whole uninstall after only the daemon had been deregistered.

The rule: guard `payload.is_a?(Hash)` before indexing, and rescue `Psych::Exception` (not just `Psych::SyntaxError`) alongside the process-signal errno set so a malformed file degrades to a no-op and teardown continues.

## Why This Matters

- **No installer drift.** With the lifecycle in one place, the bot installer can't accidentally skip the backup, mis-handle `:autostart_unavailable`, or forget shim-PATH detection. Adding a third service is a subclass, not a multi-hundred-line copy. The flip side the extraction exposed: a moved hook needs its own test. The daemon's 900s `TimeoutStopSec` warning, relocated into `upgrade_restart_warning` during extraction, was only covered by an `== :upgraded` assertion — the "byte-identical" safety net missed that one moved behavior until a test was added asserting the warning lands in `@messages` (session history).
- **macOS won't melt a CPU.** `SuccessfulExit: false` + the `/bin/sh` precheck is the only thing standing between a misconfigured bot token and an infinite respawn loop on a platform with no native respawn cap. This is invisible on Linux (systemd caps it for you) and easy to get wrong by reflex-copying a `<true/>` KeepAlive from a tutorial. The first bot plist shipped exactly that bug: KeepAlive `<true/>` while the plist's own comments described the `SuccessfulExit: false` circuit breaker — caught by the adversarial and correctness reviewers (session history).
- **Uninstall always finishes.** A corrupt pid file is exactly the kind of edge that shows up during an uninstall (the user is already in a broken state). A `TypeError` there strands the user with config wiped but services still registered. The original teardown rescued only `Psych::SyntaxError`; reviewers confirmed in a REPL that a bare-integer pid file parses cleanly to an `Integer` and slips past that rescue, and that a `Date` scalar raises `Psych::DisallowedClass` — both reasons to widen to `Psych::Exception` (session history). Warn-and-continue makes teardown idempotent and resumable.

## When to Apply

- **Learning 1** — whenever you add a new per-user autostart service, port to a new init system (Windows Service / SC, OpenRC, runit), or are tempted to copy an existing installer. Add a subclass; if a new platform needs new mechanics, push them into `Base` so both services benefit. When you relocate inline behavior into a hook, add a test for the hook — extraction does not preserve coverage of behavior that moved.
- **Learning 2** — any time you write or generate a launchd plist with `KeepAlive`. Default to `SuccessfulExit: false` plus a precheck wrapper. Reserve unconditional `<true/>` only for a process you have separately proven cannot crash-loop.
- **Learning 3** — any destructive, multi-step teardown that reads external state (pid files, lock files, sockets). Guard the parsed type before using it and rescue parse/IO errors into a no-op so one corrupt artifact can't strand the operation partway.

## Examples

**Parallel duplication (the anti-pattern) vs. shared base + thin subclass.** Before: two installers each carrying drift/backup/atomic-write/shim-PATH/enable logic. After, the whole bot subclass is identity plus rendering:

```ruby
class Bot
  class ServiceInstaller < Hive::Commands::ServiceInstaller::Base
    def service_name = "hive-bot"
    def cli_label    = "bot"
    def service_noun = "bot service"
    def unit_noun    = "bot unit"

    def target_path
      case platform
      when :macos then File.join(@home, "Library/LaunchAgents/local.hive-bot.plist")
      when :linux then File.join(@home, ".config/systemd/user/hive-bot.service")
      end
    end

    private

    def render_systemd
      template = File.read(File.expand_path("../../../../examples/systemd/hive-bot.service", __dir__))
      escaped = Shellwords.escape(resolved_binary)
      template
        .sub(/^ExecStart=.*$/, "ExecStart=#{escaped} bot start --foreground")
        .sub(/^Environment=PATH=.*$/, build_path_line)
    end
    # render_launchd: same shape, gsub the placeholder paths
  end
end
```

The daemon subclass differs only at the two seams — its ExecStart and its stop-drain warning:

```ruby
def upgrade_restart_warning
  "restarting hive-daemon; if the running daemon is mid-tick with " \
    "active children, this can block up to TimeoutStopSec (900s by " \
    "default) before returning"
end
# render_systemd subs "ExecStart=#{escaped} daemon start" + rewrites Environment=HIVE_BIN=
```

**Wrong vs. right launchd KeepAlive.**

Wrong — unconditional respawn, no native cap, busy-loops a crashing bot forever:

```xml
<key>KeepAlive</key>
<true/>
```

Right — restart only on unclean exit, plus the precheck wrapper (from `examples/launchd/hive-bot.plist`):

```xml
<key>ProgramArguments</key>
<array>
  <string>/bin/sh</string>
  <string>-c</string>
  <string>[ -x "$0" ] || exit 0; exec "$0" "$@"</string>
  <string>/Users/YOU/.local/bin/hive</string>
  <string>bot</string>
  <string>start</string>
  <string>--foreground</string>
</array>

<key>KeepAlive</key>
<dict>
  <key>SuccessfulExit</key>
  <false/>
</dict>

<key>ThrottleInterval</key>
<integer>30</integer>
```

For contrast, the Linux unit relies on systemd's built-in cap instead (`examples/systemd/hive-bot.service`):

```ini
StartLimitBurst=3
StartLimitIntervalSec=300
...
Restart=on-failure
RestartSec=10
```

**Warn-and-continue corrupt-pid guard** (`uninstall.rb`, `stop_foreground_bot`):

```ruby
def stop_foreground_bot
  pid_file = File.join(Hive::Paths.state_home, ".bot.pid")
  return unless File.exist?(pid_file)

  # The bot's pid file is a YAML Hash payload ({pid:, started_at:}),
  # unlike the daemon's bare-integer .daemon.pid. Guard is_a?(Hash)
  # before indexing: a corrupt/legacy bare scalar is still valid YAML
  # (e.g. "12345" parses to an Integer), and Integer#[] would raise an
  # unrescued TypeError that aborts the entire uninstall.
  payload = YAML.safe_load(File.read(pid_file))
  return unless payload.is_a?(Hash)

  pid = payload["pid"].to_i
  return if pid.zero?

  Process.kill("TERM", pid)
rescue Errno::ESRCH, Errno::EPERM, Errno::ENOENT, Psych::Exception
  nil
end
```

This mirrors `Bot#pid_file_payload`'s own guard (`lib/hive/commands/bot.rb`), which similarly coerces a non-Hash parse to `{}` and rescues `Psych::Exception` — the difference being that the live bot command raises a domain error ("refusing to assume bot state") whereas teardown deliberately degrades to a silent no-op so the destructive sequence can finish.

## Related

- Wiki: `[[commands/daemon]]`, `[[commands/bot]]`, `[[commands/uninstall]]`, `[[modules/bot]]`, `[[decisions]]` — descriptive pages for the commands this pattern backs.
- `docs/solutions/architecture-patterns/daemon-plan-approval-policy-exception-2026-05-15.md` — the daemon this installer installs (adjacent module, different problem).
- PR #195 (`feat/bot-autostart-service`) — the bot installer + Base extraction. PR #189 — the daemon-autostart-during-install work this was sequenced after.
