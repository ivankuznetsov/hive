---
name: hive-status
description: Show all active tasks across registered projects
version: 0.1.0
user-invocable: true
metadata: {"openclaw":{"homepage":"https://github.com/ivankuznetsov/hive"}}
---

# Hive Status

Use this skill to inspect the queue with `hive status`.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text as arguments for `hive status`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `hive status --json` when summarizing tasks for the user. Report waiting rows, recovery rows, running rows, and the exact next command Hive suggests.
