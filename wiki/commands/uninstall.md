---
title: hive uninstall
type: command
source: lib/hive/commands/uninstall.rb, lib/hive/paths.rb
created: 2026-05-21
updated: 2026-07-26
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
3. Deregister platform service units for the daemon, opt-in bot, and Hive Web using each installer's own service name and target path:
   - macOS: unload and remove the matching `local.hive-*.plist` files.
   - Linux: disable/stop the matching user services, remove their `~/.config/systemd/user/*.service` units, then daemon-reload. Each teardown warns and continues on failure so one stuck service manager never aborts the rest.
   - Hive Web identity lookup uses an explicit inert installer config, so a malformed global `web:` section cannot abort identity-only deregistration or prevent later cleanup.
   - Each thin installer delegates no-follow inspection, exact-state revalidation, manager disable, unlink, and Linux daemon-reload to `Hive::UserService`. Uninstall retains foreground-stop and multi-service/global cleanup ordering plus warning presentation.
4. Remove XDG config/cache and versioned data payload directories, unless `HIVE_HOME` collapses config/data/state/cache onto one path.
5. Remove user symlinks `hive` and `hv` under
   `${XDG_BIN_HOME:-~/.local/bin}` only when each exact target is a
   current-user regular wrapper under the active XDG data home or the prefix
   recorded by `install-prefix`, and its data home has a stable current-user
   `bash` install-channel marker. An unrelated launcher, a same-shaped
   `hive/gems/bin/` tree, or a lookalike with a symlinked marker is preserved.
6. Preserve or remove state according to `--purge` / `--force-purge-state`.

Service unit removal refuses to unlink symlinks, so a pre-planted launchd/systemd path cannot trick uninstall into deleting an arbitrary user-writable target.

## State preservation

By default, uninstall prints the XDG state directory it is preserving and lists registered project `.hive-state` paths. Interactive runs may ask whether to remove those project state directories. `--purge` suppresses the prompt and preserves them. `--force-purge-state` removes them.

When `HIVE_HOME` is set, `Hive::Paths.hive_home_collapsed?` is true. In that shape config, data, state, and cache all point at one directory, so uninstall skips broad config/cache/data deletion unless `--force-purge-state` is explicit.

## Tests

- `test/unit/commands/uninstall_test.rb` covers daemon/bot/web service removal, malformed-web-config isolation, Linux/macOS manager-failure continuation, state-preserving defaults, `--purge`, `--force-purge-state`, symlink refusal, collapsed `HIVE_HOME`, exact managed user-symlink cleanup with unowned-link preservation, and daemon pid termination.
- `test/unit/paths_test.rb` covers XDG path resolution and legacy registry migration helpers used by install/uninstall surfaces.

## Backlinks

- [[cli]] · [[operating]] · [[modules/config]]
