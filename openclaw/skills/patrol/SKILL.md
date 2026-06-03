---
name: patrol
description: Run an opt-in Hive repository patrol scan for a registered project
version: 0.1.0
user-invocable: true
metadata: {"openclaw": {"homepage": "https://github.com/ivankuznetsov/hive", "requires": {"bins": ["hive"]}}}
---

# Hive Patrol

Use this skill to run `hive patrol PROJECT`.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text as arguments for `hive patrol`. If the project argument is missing, ask one concise question or run `hive projects --help` / `hive patrol --help` if available in the installed Hive version. Run the command from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when you need structured output. Use `--dry-run` when the user wants a review-only scan without attempted fixes or GitHub PR creation. Patrol is opt-in per registered project through `patrol.enabled`; do not enable it or change validation commands unless the user explicitly asks.
