---
name: init
description: Bootstrap .hive-state (orphan hive/state branch); TTY-prompts for agents + limits
version: 0.1.0
user-invocable: true
metadata: {"openclaw": {"homepage": "https://github.com/ivankuznetsov/hive", "requires": {"bins": ["hive"]}}}
---

# Hive Init

Use this skill to run `hive init [PROJECT_PATH]`.

Before running anything, check `command -v hive`. If it is missing, tell the user to run the umbrella `/hive setup` guided setup flow first.

Treat the user's slash-command text as arguments for `hive init`. If no path is supplied, initialize the current project only after confirming that is what the user wants. Pass arguments safely; do not interpolate raw user text into a shell string.

Warning: `hive init` may run interactive TTY prompts (planning agent, dev agent, reviewers, triage bias, daemon enrollment, etc). OpenClaw skill contexts often do not allocate an interactive TTY — when that is true, init detects it and falls back to defaults, then prints a one-line summary. `--json` only changes the output envelope; it does not suppress prompts when stdin is a TTY. If the calling shell exposes a TTY and the agent cannot answer prompts, do not run init interactively. Ask the user for confirmation, or run with stdin redirected from `/dev/null` such as `hive init PROJECT --json </dev/null`, then hand-edit `.hive-state/config.yml` (see `wiki/modules/config.md`) to customize non-default values.

After initialization, run `hive doctor` non-fatally and summarize any missing agent skills or dependencies.
