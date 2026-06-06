---
name: run
description: Run the stage agent for TARGET (slug or task folder)
version: 0.1.0
user-invocable: true
metadata: {"openclaw": {"homepage": "https://github.com/ivankuznetsov/hive", "requires": {"bins": ["hive"]}}}
---

# Hive Run

Use this skill to run `hive run TARGET`.

Before running anything, check `command -v hive`. If it is missing, tell the user to run the umbrella `/hive setup` guided setup flow first.

Treat the user's slash-command text as arguments for `hive run`. If the target is missing, ask one concise question or run `hive run --help`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when you need structured output. Summarize the stage runner result, marker, worktree path, and next command.
