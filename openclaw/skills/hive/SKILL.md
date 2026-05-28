---
name: hive
description: Drive any Hive CLI workflow from OpenClaw.
version: 0.1.0
user-invocable: true
metadata: {"openclaw":{"homepage":"https://github.com/ivankuznetsov/hive"}}
---

# Hive CLI

Use this skill when the user wants to inspect, create, advance, review, or administer Hive tasks through the `hive` CLI.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text after `/hive` as arguments for `hive`. If no arguments are supplied, run `hive --help` and summarize the available workflow. Run commands from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when the Hive command supports it and you need structured output. Summarize the result, including task slug, stage/action, marker, and next command when present.
