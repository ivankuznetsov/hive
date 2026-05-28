---
name: ce-review
description: Move a completed open-pr task into review, or run an existing review task
version: 0.1.0
user-invocable: true
metadata:
  openclaw:
    homepage: https://github.com/ivankuznetsov/hive
    requires:
      bins:
        - hive
---

# Hive CE Review

Use this skill to run Hive's autonomous review loop with `hive review TARGET`. `ce-review` is the OpenClaw shortcut for Hive's `review` workflow verb.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text as arguments for `hive review`. If the target is missing, ask one concise question or run `hive review --help`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when you need structured output. Summarize CI status, reviewer findings, triage outcome, and whether Hive advanced or stopped for user input.
