---
name: hive-approve
description: Move a task to the next stage (or --to <stage>); agent-callable equivalent of `mv`
version: 0.1.0
user-invocable: true
metadata: {"openclaw": {"homepage": "https://github.com/ivankuznetsov/hive", "requires": {"bins": ["hive"]}}}
---

# Hive Approve

Use this skill to run `hive approve TARGET`.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text as arguments for `hive approve`. If the target is missing, ask one concise question or run `hive approve --help`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when you need structured output. Summarize the source stage, destination stage, marker, and next command.

Before passing `--force`, restate that it bypasses the terminal-marker safety check and get explicit user confirmation.
