---
name: hive
description: Drive any Hive CLI workflow from OpenClaw.
version: 0.1.0
user-invocable: true
metadata: {"openclaw": {"homepage": "https://github.com/ivankuznetsov/hive", "requires": {"bins": ["hive"]}}}
---

# Hive CLI

Use this skill when the user wants to inspect, create, advance, review, or administer Hive tasks through the `hive` CLI.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text after `/hive` as arguments for `hive`. If no arguments are supplied, run `hive --help` and summarize the available workflow. Run commands from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when the Hive command supports it and you need structured output. Summarize the result, including task slug, stage/action, marker, and next command when present.

Before running destructive admin verbs (`drop`, `uninstall`, `update`, `forget`, `prune`, `migrate`, or `metrics`), restate the effect and get explicit user confirmation. These verbs can kill agents, remove worktrees, close draft PRs, drop registry entries, or rewrite installed software — they are not undoable.

Before running nested destructive or bypass commands (`daemon stop`, `daemon disable --all`, `daemon install --force`, `bot stop`, `bot install --force`, `markers clear`, or `approve --force`), restate the effect and get explicit user confirmation. These can stop background automation, replace autostart services, clear recovery markers, or skip terminal-marker safety.

Prefer `hive daemon start --detach` for daemon startup. Before running `hive daemon start` without `--detach`, `hive daemon tail`, `hive bot start --foreground`, or `hive bot tail`, restate that the command can hold the agent in a foreground or streaming process and get explicit user confirmation.
