---
name: hive
description: >-
  Operate Hive's folder-based coding-agent workflows from OpenClaw: guided CLI
  setup, reviewed workflow packages, task pipelines, patrols, web/TUI status,
  and consent-gated administration.
version: 0.1.3
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

Hive turns a repository into durable agent workflows. Its built-in coding
workflow moves tasks through brainstorm, plan, execute, open PR, review,
artifacts, and finalize stages. Reviewed Honeycomb packages provide additional
workflows, and the daemon advances enrolled projects in the background.

Use this skill to install or operate the Hive CLI, including native Hive web.
It is a command adapter, not permission to mutate the host: inspect first and
apply the consent rules below.

## Install From ClawHub

Install the single public skill with:

```bash
openclaw skills install @ivankuznetsov/hive-cli
```

This installs the `/hive` slash command. First use is normally:

```text
/hive setup
```

## Common Paths

- `/hive setup` verifies or installs Hive, provisions local web/daemon support,
  and offers to enroll the current project. Hive's normal all-in-one native
  provisioning command is `hive setup --json`; this guided flow uses
  `--no-init` so enrollment remains interactive.
- `/hive setup --no-service` performs the remaining setup work without
  installing, enabling, starting, stopping, or disabling Hive web.
- `/hive doctor --json` diagnoses the runtime and managed agent skills without
  changing them; `/hive setup-agents` previews unresolved managed skills and
  asks once before provisioning.
- `/hive status --json` shows task stages, markers, holds, PR URLs, and next
  actions. `/hive tui` provides the live terminal view.
- `/hive web status --json` observes the native web service without mutation.
- `/hive web` bootstraps and starts Hive web in the foreground; it blocks until
  stopped.
- `/hive new . "build this feature"` creates a task. `/hive plan <task-slug>`,
  `/hive develop <task-slug>`, and `/hive review <task-slug>` operate the main
  coding path.
- `/hive workflow install honeycomb/<name>` installs a reviewed workflow
  package. `/hive workflow list --json` inspects installed generations.
- `/hive patrol <project>` runs an ordinary defect patrol; `/hive refactor-patrol
  <project>` discovers architecture improvements.
- `/hive digest` produces the daily shipped digest. `/hive bench submit <task-slug>`
  prepares a completed task for the hive-bench corpus.
- `/hive wiki compile-log --check` verifies `wiki/log.md` against fragments in
  `wiki/log.d/`.

Current Hive also enforces declared task dependencies before dispatch, retains
durable ownership across retries, and applies scoped tool/file permissions to
reviewed workflow actors. These are runtime guarantees, not extra commands the
agent should reproduce.

## Custom Workflows

Hive supports project-authored workflows for writing, feedback triage,
research, and other staged work:

```bash
hive workflow new <id> [--template <name>]
hive init . --workflow <id>
hive new . --workflow <id> "draft launch notes"
```

Reviewed Honeycomb packages use a separate lifecycle. First preview the exact
operation with a supported no-write command:

```bash
hive workflow install honeycomb/<name> --dry-run --json
hive workflow update <name> --dry-run --json
hive workflow remove <name> --dry-run --json
```

After the user reviews that output and explicitly approves the disclosed
mutation, execute only the corresponding command:

```bash
hive workflow install honeycomb/<name> --yes --json
hive workflow update <name> --yes --json
hive workflow remove <name> --yes --json
```

Never append `--yes` unless the user explicitly pre-authorized the displayed
action. If the preview discloses high risk or permission growth, explain that
separately and get separate explicit approval before adding
`--allow-escalation`; do not infer escalation authorization from ordinary
install or update consent. Use `hive workflow list --json` for read-only
inspection of installed generations.

Managed agent-skill provisioning follows the same preview/approval split:

```bash
hive setup-agents --json
# Only after the user approves the returned plan:
hive setup-agents --yes --json
```

When changes are planned, the preview's consent-required response and nonzero
exit are expected; present its plan rather than treating that response as a
failure. The `--yes` execution must match the scope the user reviewed.

Agent and council stages may declare `budget_usd` and `timeout_sec`. These are
per-spawn limits. On subscription-backed providers, a native budget field is a
runaway guard and does not mean Hive is making an additional payment.

## CLI Detection

Before dispatch, detect Hive without confusing it with Apache Hive:

```bash
if hive --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  hive_cmd=hive
elif hv --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  hive_cmd=hv
else
  hive_cmd=
fi
```

If `hive_cmd` is empty, offer guided setup. Explain that setup installs the CLI
and provisions the per-user daemon and loopback Hive web services; initial
project enrollment remains a separate step. Get explicit user confirmation
before running an installer. On Windows, use WSL with systemd enabled for the
native path or offer Hivebox; do not invent a native Windows service manager.

## Guided Setup

Show the chosen command and wait for confirmation. Keep the package manager's
normal transaction review and confirmation prompt; never add flags that
suppress it.

- macOS arm64: `brew tap ivankuznetsov/hive && brew install ivankuznetsov/hive/hive`
- Arch Linux with yay: `yay -S --needed hive-bin`
- Arch Linux with paru: `paru -S --needed hive-bin`
- Ubuntu 22.04+ or compatible glibc Linux x86_64/aarch64:

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/v0.6.4/install.sh -o "$tmpdir/hive-install.sh"
bash "$tmpdir/hive-install.sh"
```

For Arch Linux, display the selected `yay` or `paru` transaction for the user
to run in their own real terminal. Do not execute it through a non-TTY tool
call, and never add `--noconfirm`; the operator must review and confirm the
package-manager transaction interactively.

The Linux installer obtains and verifies the signed release artifact. After an
approved install, repeat the strict `hive` / `hv` version check. If neither
prints a bare `X.Y.Z`, stop and report failure or possible Apache Hive
shadowing. If verification succeeds, run
`"${hive_cmd}" setup --no-init --json` for core provisioning and summarize the
installed version, every setup phase, exact service/install outcome, explicitly
skipped enrollment, and any diagnose-only login instructions. Parse `mode`,
`url`, `service.service_installed`, `service.service_enabled`,
`service.service_running`, `service.ready`, `service.readiness`, `warnings`, and
`phases`. Report the effective URL, distinct service state, and compatibility
warnings; never describe the URL as available unless `service.ready` is true.

Setup's untouched configuration is loopback-only. Never add or widen a bind,
origin, reverse proxy, or Tailscale Serve rule. If setup reports an existing
explicitly gated non-loopback origin, report that observed operator choice
without replacing it. Legacy native-web `HIVEBOX_*` aliases may appear in the
JSON `warnings`; name their `HIVE_WEB_*` replacements. Container-only Hivebox
settings remain canonical and must not be presented as deprecated.

Initial project enrollment is a separate, consent-gated step. Explain that a
non-TTY `hive init` takes defaults that enable medium patrol, architecture
discovery, daemon dispatch, and the babysitter. Those facilities consume
provider subscription capacity and can eventually open PRs. After the user has
reviewed and explicitly approved enrollment, ask them to run `hive init .` in
their own real terminal. They can choose patrol mode `off` and answer no to the
architecture patrol, daemon, and babysitter prompts; do not invent a
`--no-patrol` flag or run init headlessly on their behalf.

`/hive install` and `/hive bootstrap` are aliases for this guided flow.

## Dispatch Rules

Otherwise, treat the user's slash-command text after `/hive` as arguments for `hive_cmd`.
With no arguments, run `"${hive_cmd}" --help`. Run from the current
workspace unless the user named another project. Pass arguments safely as an
argv array; never interpolate raw user text into a shell string.

Prefer `--json` for inspection and summarize the task slug, stage, marker,
action, hold/retry state, PR URL, and suggested next command when present.

For web inspection, prefer `hive web status --json`; its
`hive-web-status.v1` envelope separates installed, enabled, running, and ready.
Run bare `hive web` only when the user explicitly wants the blocking foreground
server. Run `hive web install --force` only for an explicitly approved repair
of a drifted managed unit.

Daemon auto-advance is covered by the user's previously approved enrollment.
When the enrolled coding daemon is healthy, a printed `next:` line is a
manual fallback or recovery command: do not execute the printed command merely
because it appeared. Let the daemon own ordinary progression. Stop for
`needs_input`, unanswered questions, destructive or external actions, Safety
Boundaries actions, or a request for manual control. When uncertain, inspect
`hive daemon status --json`; if the daemon or enrollment is absent, offer the
printed command as an optional action and wait for approval.

For `hive wiki compile-log`, use `--check` for verification. Run the mutating
compiler only after merge/rebase or when explicitly requested; feature changes
add `wiki/log.d/<timestamp>-<slug>.md` instead of editing compiled `wiki/log.md`.

## Patrol And Architecture Patrol

Patrol is opt-in autonomous agent work and consumes the operator's provider
subscription. Before starting a manual `/hive patrol` or `/hive
refactor-patrol`, show the project, current `patrol.mode`, and whether the run
can open PRs, then get explicit user confirmation. An already configured daemon
schedule carries its prior consent; monitor it without re-confirming each tick.

The `low`, `medium`, `high`, and `ultrapatrol` tiers have successively larger
per-cycle launch and token ceilings. Architecture patrol gets 2x the selected
tier's per-cycle and per-agent allowance because cross-boundary analysis needs
more context, while both patrol types retain the same shared daily ceiling and
provider-native budget guard. Missing usage telemetry still consumes launch
quota. Do not describe this as a paid patrol: on subscription-backed agents it
uses the existing subscription.

Token statistics in `hive tui` are a human-only interactive handoff: ask the
user to open it and press `T` to inspect today/7d/30d/all usage, including the
combined patrol attribution row. An agent may report configured limits and an
observed hold/retry state from machine-readable output, but must not claim exact
token totals because this skill documents no machine-readable token-stat
command. If headroom is exhausted, report the hold or retry time; do not bypass
the configured limit or start parallel patrols.

## Status Bundle

For a read-only overview, gather:

```bash
hive daemon status --json
hive status --json
systemctl --user status hive-daemon.service --no-pager
```

For each task with a PR URL, run `gh pr checks <number>` when `gh` is available.
Summarize `stage`, `marker`, `action`, `PR URL`, `CI status`, `live PID`,
`held/retry`, and `suggested command`. On macOS or without `systemctl`/`gh`,
report the unavailable field instead of failing the bundle.

## Watch Selected Tasks

When asked to monitor tasks, use bounded polling of `hive status --json` with a
clear interval and timeout (defaults: 15 seconds and 30 minutes). Report only
meaningful state changes and PR availability, call out entry into `7-artifacts`
or `8-finalize`, and return a final snapshot at timeout. Ctrl-C is safe: this
watch never kills Hive agents, never clears markers, and never advances stages.

## Daemon Diagnostics And Repair

Diagnose before repairing:

```bash
command -v hive
hive --version
hive doctor --json
hive daemon status --json
systemctl --user cat hive-daemon.service
```

If `systemctl` is unavailable, use the platform service details returned by
Hive. Explain binary drift, missing dependencies, or service state from these
read-only results before proposing a fix.

Never patch an installed Hive runtime or write service-manager configuration
directly. Prefer Hive-native setup and repair commands:

```bash
hive setup --no-init --json
hive daemon install --force --json
hive daemon status --json
```

The `--no-init` setup form repairs core provisioning without enrolling the
current project; enrollment remains the separate interactive Guided Setup step
described above. `setup` and `daemon install --force` change persistent
per-user state. Show the specific command and diagnosis, restate the effect,
and get explicit user confirmation before running either repair. Afterward,
verify with doctor, version, and daemon status. If Hive reports a
dependency-specific manual command, present it for review; do not execute it
automatically.

## Safety Boundaries

Read-only inspection includes `status`, `doctor`, `rebase-status`, `findings`,
`metrics`, daemon/bot status, and workflow list. The exact Honeycomb lifecycle
previews documented above (`workflow install`, `workflow update`, and `workflow
remove`, each with `--dry-run --json`) are also no-write inspections. These do
not need confirmation.

Do not generalize that exemption to every `--dry-run` command. In particular,
`hive patrol ... --dry-run` and `hive refactor-patrol ... --dry-run` still
launch agents and consume subscription capacity; ordinary patrol dry-run may
also persist scan state. Both remain consent-gated patrol starts.

Before destructive or persistent admin verbs (`drop`, `uninstall`, `update`,
`forget`, `prune`, or `migrate`), restate the effect and get explicit user confirmation.
Apply the same rule to workflow install/update/remove/publish,
`setup-agents`, patrol starts, outbound `digest`/`bench submit`, and nested
commands `daemon stop`, `daemon disable --all`, `daemon install --force`,
`web install --force`, `bot stop`, `bot install --force`, `markers clear`, or
`approve --force`.

Prefer `hive daemon start --detach` for startup. Before `hive daemon start`
without detach, `hive web`, `hive daemon tail`, `hive bot start --foreground`,
or `hive bot tail`, explain that it can hold the session and get explicit user
confirmation.

## Marker Recovery

Inspect with `hive status --json` and `hive daemon status --json`. If the daemon
is stopped, offer `hive daemon start --detach`. When it is running, let the
healer handle known bounded recovery cases:

1. `REVIEW_ERROR phase=fix reason=fix_failed` with
   `claude stop hook did not signal completion`: let the healer retry; ask before a manual clear only
   after its budget is exhausted.
2. Other `fix_failed`: investigate the actual fix failure. It is manual; ask
   before clearing.
3. `limits_reached` with valid `retry_after`: wait for the cooldown and let the
   healer requeue. A missing or malformed retry time is manual.
4. Stale `agent_working`: a live PID/lock means wait; an orphaned agent may be
   healer-managed; a dead agent rewritten to `ERROR reason=agent_died` is
   manual.
5. Other documented healer-managed errors: let the healer use its bounded
   retry budget, then ask before intervention.
6. Terminal/manual `ERROR`: inspect the reason and ask before clearing it.

`hive markers clear` mutates task state and always follows Safety Boundaries.
After explicit approval, prefer an observed marker identity:

```bash
hive markers clear <folder> --name ERROR --match-attr marker_id=<id>
```

Then rerun only the stage-specific recovery command reported by current status.
