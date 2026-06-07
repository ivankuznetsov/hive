---
name: hive
description: >-
  Run Hive's folder-based coding-agent pipeline from OpenClaw: guided CLI setup,
  project init, task creation, plan/develop/review workflows, status, daemon,
  and guarded admin commands.
version: 0.1.1
user-invocable: true
metadata:
  openclaw:
    homepage: https://github.com/ivankuznetsov/hive
    always: true
    install:
      - id: homebrew
        kind: brew
        formula: ivankuznetsov/hive/hive
        bins: [hive]
        label: Install Hive CLI with Homebrew
        os: [darwin]
---

# Hive CLI

Hive turns a repository into a folder-based coding-agent pipeline: ideas become tasks, tasks move through brainstorm, plan, develop, review, artifacts, and finalize stages, and the daemon keeps enrolled projects moving in the background.

Use this skill when the user wants to install Hive from OpenClaw, initialize the current project, create a task, inspect status, move a task through plan/develop/review, run diagnostics, or administer Hive's daemon, bot, markers, metrics, and task registry.

## Install From ClawHub

Users install the OpenClaw skill with:

```bash
openclaw skills install hive-cli
```

That listing installs the `/hive` slash command. First run should normally be:

```text
/hive setup
```

## Common Paths

- `/hive setup` installs or verifies the Hive CLI, enables the per-user daemon service, and optionally initializes the current repository.
- `/hive status --json` shows the task board and next actions.
- `/hive new . "build this feature"` creates a new Hive task in the current project.
- `/hive plan <task-slug>`, `/hive develop <task-slug>`, and `/hive review <task-slug>` advance a task through the main coding workflow.
- `/hive doctor` checks local runtime and skill configuration.

## CLI Detection

Before running a Hive workflow, check whether the Hive CLI is installed:

```bash
if hive --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  hive_cmd=hive
elif hv --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  hive_cmd=hv
else
  hive_cmd=
fi
```

If `hive_cmd` is empty, start guided setup instead of failing. Restate that setup will install the Hive CLI, verify it, install or enable the per-user daemon service, and optionally run `hive init` for the current project. Get explicit user confirmation before running installers.

## Guided Setup

Use the host platform to choose one install path:

- macOS arm64: `brew tap ivankuznetsov/hive && brew install ivankuznetsov/hive/hive`.
- Arch Linux with `yay`: `yay -S --noconfirm --needed hive-bin`.
- Arch Linux with `paru`: `paru -S --noconfirm --needed hive-bin`.
- Ubuntu 22.04+ / glibc Linux x86_64 or aarch64:

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/v0.2.0/install.sh -o "$tmpdir/hive-install.sh"
bash "$tmpdir/hive-install.sh"
```

After install, run the strict `hive` / `hv` version check again. If neither command prints a bare `X.Y.Z` version, stop and report that setup failed or Apache Hive may be shadowing the command. If verification succeeds, run `"${hive_cmd}" daemon install` once. Then ask whether to initialize the current project; if yes, run `"${hive_cmd}" init . --json </dev/null`, followed by `"${hive_cmd}" doctor` non-fatally. Summarize the installed version, daemon setup result, project initialization result, and any missing runtime dependencies.

## Dispatch Rules

Treat `/hive setup`, `/hive install`, and `/hive bootstrap` as requests for the guided setup flow above. Otherwise, treat the user's slash-command text after `/hive` as arguments for `hive_cmd`. If no arguments are supplied and Hive is already installed, run `"${hive_cmd}" --help` and summarize the available workflow. Run commands from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when the Hive command supports it and you need structured output. Summarize the result, including task slug, stage/action, marker, and next command when present.

## Safety Boundaries

Before running destructive admin verbs (`drop`, `uninstall`, `update`, `forget`, `prune`, `migrate`, or `metrics`), restate the effect and get explicit user confirmation. These verbs can kill agents, remove worktrees, close draft PRs, drop registry entries, or rewrite installed software — they are not undoable.

Before running nested destructive or bypass commands (`daemon stop`, `daemon disable --all`, `daemon install --force`, `bot stop`, `bot install --force`, `markers clear`, or `approve --force`), restate the effect and get explicit user confirmation. These can stop background automation, replace autostart services, clear recovery markers, or skip terminal-marker safety.

Prefer `hive daemon start --detach` for daemon startup. Before running `hive daemon start` without `--detach`, `hive daemon tail`, `hive bot start --foreground`, or `hive bot tail`, restate that the command can hold the agent in a foreground or streaming process and get explicit user confirmation.
