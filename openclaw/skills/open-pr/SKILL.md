---
name: open-pr
description: Move a completed execute task into open-pr, or run an existing open-pr task
version: 0.1.0
user-invocable: true
metadata:
  openclaw:
    homepage: https://github.com/ivankuznetsov/hive
    requires:
      bins:
        - hive
---

# Hive Open PR

Use this skill to run `hive open-pr TARGET`.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text as arguments for `hive open-pr`. If the target is missing, ask one concise question or run `hive open-pr --help`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when you need structured output. Summarize the PR URL, draft state, and next Hive command when present.
