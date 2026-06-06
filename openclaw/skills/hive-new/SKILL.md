---
name: hive-new
description: Create a new task in 1-inbox of PROJECT
version: 0.1.0
user-invocable: true
metadata: {"openclaw": {"homepage": "https://github.com/ivankuznetsov/hive", "requires": {"bins": ["hive"]}}}
---

# Hive New

Use this skill to capture a new idea with `hive new PROJECT TEXT`.

Before running anything, check `command -v hive`. If it is missing, tell the user to run the umbrella `/hive setup` guided setup flow first.

Treat the user's slash-command text as arguments for `hive new`. If the project or task text is missing, ask one concise question. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

After the command finishes, report the created task slug and the project it was added to.
