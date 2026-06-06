---
name: accept-finding
description: Tick `[x]` on review findings (toggle to accepted)
version: 0.1.0
user-invocable: true
metadata: {"openclaw": {"homepage": "https://github.com/ivankuznetsov/hive", "requires": {"bins": ["hive"]}}}
---

# Hive Accept Finding

Use this skill to run `hive accept-finding TARGET [ID...]`.

Before running anything, check `command -v hive`. If it is missing, tell the user to run the umbrella `/hive setup` guided setup flow first.

Treat the user's slash-command text as arguments for `hive accept-finding`. If the target or selector is missing, ask one concise question or run `hive accept-finding --help`. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when you need structured output. Summarize which finding IDs were accepted and whether another `hive develop` run is now appropriate.
