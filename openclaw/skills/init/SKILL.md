---
name: init
description: Bootstrap .hive-state (orphan hive/state branch); TTY-prompts for agents + limits
version: 0.1.0
user-invocable: true
metadata:
  openclaw:
    homepage: https://github.com/ivankuznetsov/hive
    requires:
      bins:
        - hive
---

# Hive Init

Use this skill to run `hive init [PROJECT_PATH]`.

Before running anything, check `command -v hive`. If it is missing, stop and tell the user to install Hive with Homebrew, AUR, RubyGems, or the installer in https://github.com/ivankuznetsov/hive.

Treat the user's slash-command text as arguments for `hive init`. If no path is supplied, initialize the current project only after confirming that is what the user wants. Pass arguments safely; do not interpolate raw user text into a shell string.

Warning: `hive init` may run interactive TTY prompts (planning agent, dev agent, reviewers, triage bias, daemon enrollment, etc). OpenClaw skill contexts often do not allocate an interactive TTY — when that is true, init detects it and falls back to defaults, then prints a one-line summary. If the calling shell DOES expose a TTY but the agent cannot answer the prompts, init will block forever. Prefer running with `--json` to suppress prose and emit a structured envelope on success, then hand-edit `.hive-state/config.yml` (see `wiki/modules/config.md`) to customize non-default values.

After initialization, run `hive doctor` non-fatally and summarize any missing agent skills or dependencies.
