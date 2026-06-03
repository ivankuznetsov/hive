---
name: babysit
description: Manage the experimental hive-babysitter (start / stop / status / reload / tail / --once)
version: 0.1.0
user-invocable: true
metadata: {"openclaw": {"homepage": "https://github.com/ivankuznetsov/hive", "requires": {"bins": ["hive"]}}}
---

# Hive Babysitter

Use this skill to run `hive babysit SUBCOMMAND`.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text as arguments for `hive babysit`. If the subcommand is missing, ask one concise question or run `hive babysit --help`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` for lifecycle commands when you need structured output. Prefer `hive babysit start --detach` when the user asks to start the babysitter. Before foreground `start` without `--detach`, streaming `tail`, `stop`, or `--once --all`, restate the effect and get explicit user confirmation.
