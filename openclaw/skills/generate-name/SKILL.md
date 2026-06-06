---
name: generate-name
description: Generate a human-readable display name for TARGET
version: 0.1.0
user-invocable: true
metadata: {"openclaw": {"homepage": "https://github.com/ivankuznetsov/hive", "requires": {"bins": ["hive"]}}}
---

# Hive Generate Name

Use this skill to run `hive generate-name TARGET` for a task that needs a human-readable display title.

Before running anything, check `command -v hive`. If it is missing, tell the user to run the umbrella `/hive setup` guided setup flow first.

Treat the user's slash-command text as arguments for `hive generate-name`. If the task target is missing, ask one concise question. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

The target can be a numeric task id, slug, or task folder path. Report the generated name when the command prints one; if it prints nothing, explain that generation is best-effort and the task will keep using the slug fallback.
