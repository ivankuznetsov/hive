---
name: daemon
description: Manage the hive daemon (start / stop / status / reload / tail / install / enable / disable)
version: 0.1.0
user-invocable: true
metadata: {"openclaw": {"homepage": "https://github.com/ivankuznetsov/hive", "requires": {"bins": ["hive"]}}}
---

# Hive Daemon

Use this skill to run `hive daemon SUBCOMMAND`.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text as arguments for `hive daemon`. If the subcommand is missing, ask one concise question or run `hive daemon --help`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` for `status`, `stop`, `reload`, `install`, `enable`, and `disable` when you need structured output. Prefer `hive daemon start --detach` when the user asks to start the daemon. Before foreground `start` without `--detach`, streaming `tail`, `install --force`, `disable --all`, or `stop`, restate the effect and get explicit user confirmation.
