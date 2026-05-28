---
name: finalize
description: Move a completed artifacts task into finalize, or run an existing finalize task
version: 0.1.0
user-invocable: true
metadata: {"openclaw":{"homepage":"https://github.com/ivankuznetsov/hive"}}
---

# Hive Finalize

Use this skill to run `hive finalize TARGET`.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text as arguments for `hive finalize`. If the target is missing, ask one concise question or run `hive finalize --help`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when you need structured output. Summarize the PR state, ready-for-review action, marker, and next command.
