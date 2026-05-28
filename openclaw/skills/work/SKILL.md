---
name: work
description: Move a completed plan task into execute, or run an existing execute task
version: 0.1.0
user-invocable: true
metadata: {"openclaw":{"homepage":"https://github.com/ivankuznetsov/hive"}}
---

# Hive Work

Use this skill to implement work by running `hive develop TARGET`. `work` is the OpenClaw shortcut for Hive's `develop` workflow verb.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text as arguments for `hive develop`. If the target is missing, ask one concise question or run `hive develop --help`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when you need structured output. Summarize the worktree path, branch, marker, and any review findings Hive reports.
