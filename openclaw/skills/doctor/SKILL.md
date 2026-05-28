---
name: doctor
description: Verify each stage's configured skill is installed for its agent
version: 0.1.0
user-invocable: true
metadata:
  openclaw:
    homepage: https://github.com/ivankuznetsov/hive
    requires:
      bins:
        - hive
---

# Hive Doctor

Use this skill to run `hive doctor`.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text as arguments for `hive doctor`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `hive doctor --json` when summarizing checks. Report missing skills, missing dependencies, and the exact install hint Hive prints.
