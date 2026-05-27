---
title: hive uninstall
type: command
source: lib/hive/commands/uninstall.rb, lib/hive/paths.rb
created: 2026-05-21
updated: 2026-05-27
tags: [command, install, uninstall, xdg]
---

**TLDR**: `hive uninstall` removes user-scoped Hive registrations, service units, cache/config, versioned bash payloads, and user symlinks while preserving accumulated work by default.

## Usage

```bash
hive uninstall
hive uninstall --purge
hive uninstall --force-purge-state
```

`--purge` is non-interactive but still preserves state. `--force-purge-state` is the explicit destructive path that removes accumulated Hive state and registered project `.hive-state` directories.

## Cleanup sequence

1. Read registered projects from global config. Config errors become warnings and skip per-project cleanup.
2. Stop a foreground daemon using the XDG state-home `.daemon.pid` when present, and a foreground bot using `.bot.pid` (a YAML payload; a corrupt/legacy pid file degrades to a no-op rather than aborting uninstall).
3. Deregister platform service units (both the daemon and the opt-in bot autostart service from `hive bot install`):
   - macOS: unload and remove `~/Library/LaunchAgents/local.hive-daemon.plist` and `local.hive-bot.plist`.
   - Linux: `systemctl --user disable --now hive-daemon` / `hive-bot`, remove `~/.config/systemd/user/hive-daemon.service` / `hive-bot.service`, then daemon-reload. Each teardown warns and continues on failure so one stuck service manager never aborts the rest.
4. Remove XDG config/cache and versioned data payload directories, unless `HIVE_HOME` collapses config/data/state/cache onto one path.
5. Remove user symlinks `hive` and `hv` under `${XDG_BIN_HOME:-~/.local/bin}` when they are symlinks.
6. Preserve or remove state according to `--purge` / `--force-purge-state`.

Service unit removal refuses to unlink symlinks, so a pre-planted launchd/systemd path cannot trick uninstall into deleting an arbitrary user-writable target.

## State preservation

By default, uninstall prints the XDG state directory it is preserving and lists registered project `.hive-state` paths. Interactive runs may ask whether to remove those project state directories. `--purge` suppresses the prompt and preserves them. `--force-purge-state` removes them.

When `HIVE_HOME` is set, `Hive::Paths.hive_home_collapsed?` is true. In that shape config, data, state, and cache all point at one directory, so uninstall skips broad config/cache/data deletion unless `--force-purge-state` is explicit.

## Tests

- `test/unit/commands/uninstall_test.rb` covers service removal, state-preserving defaults, `--purge`, `--force-purge-state`, symlink refusal, collapsed `HIVE_HOME`, user symlink cleanup, and daemon pid termination.
- `test/unit/paths_test.rb` covers XDG path resolution and legacy registry migration helpers used by install/uninstall surfaces.

## Backlinks

- [[cli]] · [[operating]] · [[modules/config]]
