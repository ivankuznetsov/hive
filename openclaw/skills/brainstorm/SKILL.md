---
name: brainstorm
description: Move an inbox task into brainstorm, or run an existing brainstorm task
version: 0.1.0
user-invocable: true
metadata:
  openclaw:
    homepage: https://github.com/ivankuznetsov/hive
    requires:
      bins:
        - hive
---

# Hive Brainstorm

Use this skill to run `hive brainstorm TARGET`.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text as arguments for `hive brainstorm`. If the target is missing, ask one concise question or run `hive brainstorm --help`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when you need structured output. Summarize the resulting marker and tell the user which file needs edits if Hive returns a waiting state.
