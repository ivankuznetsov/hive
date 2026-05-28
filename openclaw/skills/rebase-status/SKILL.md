---
name: rebase-status
description: Print the auto-rebase status for TARGET without running anything (read-only)
version: 0.1.0
user-invocable: true
metadata:
  openclaw:
    homepage: https://github.com/ivankuznetsov/hive
    requires:
      bins:
        - hive
---

# Hive Rebase Status

Use this skill to run `hive rebase-status TARGET`.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text as arguments for `hive rebase-status`. If the target is missing, ask one concise question or run `hive rebase-status --help`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when you need structured output. Summarize whether Hive would rebase, skip, or block, and include the reason.
