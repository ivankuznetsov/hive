---
name: plan
description: Move a completed brainstorm task into plan, or run an existing plan task
version: 0.1.0
user-invocable: true
metadata: {"openclaw": {"homepage": "https://github.com/ivankuznetsov/hive", "requires": {"bins": ["hive"]}}}
---

# Hive Plan

Use this skill to run `hive plan TARGET`.

Before running anything, check `command -v hive`. If it is missing, tell the user to run the umbrella `/hive setup` guided setup flow first.

Treat the user's slash-command text as arguments for `hive plan`. If the target is missing, ask one concise question or run `hive plan --help`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when you need structured output. Summarize the resulting marker and tell the user which `plan.md` file needs edits when Hive asks for review.
