---
name: archive
description: List done tasks, or move a completed finalize task into done
version: 0.1.0
user-invocable: true
metadata: {"openclaw": {"homepage": "https://github.com/ivankuznetsov/hive", "requires": {"bins": ["hive"]}}}
---

# Hive Archive

Use this skill to run `hive archive [TARGET]`.

Before running anything, check `command -v hive`. If it is missing, tell the user to run the umbrella `/hive setup` guided setup flow first.

Treat the user's slash-command text as arguments for `hive archive`. With no target, run `hive archive` to list every task currently in `9-done`; with a target, run the workflow form that moves a completed finalize task into done or reruns an existing done task. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when you need structured output. For no-target listings, summarize the archived tasks found; for targeted archive runs, summarize whether the task reached `9-done`.
