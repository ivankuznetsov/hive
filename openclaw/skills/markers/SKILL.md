---
name: markers
description: Manage state-file markers (clear)
version: 0.1.0
user-invocable: true
metadata: {"openclaw":{"homepage":"https://github.com/ivankuznetsov/hive"}}
---

# Hive Markers

Use this skill to run `hive markers SUBCOMMAND FOLDER`.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text as arguments for `hive markers`. If the subcommand, folder, or marker name is missing, ask one concise question or run `hive markers --help`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when you need structured output. Include any `--match-attr` guard Hive suggests so stale recovery cannot clear a newer marker.
