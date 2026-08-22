# Getting Started

This page gets you through the first operator-driven loop: install Hive, attach it to a real project, capture an idea, run brainstorm, and promote the task to plan. The full pipeline can take longer because agents do real work; five minutes is the active time you spend driving the first handoffs.

The example is xbookmark, a real Hive dogfood task that finished as [xbookmark PR #1](https://github.com/ivankuznetsov/xbookmark/pull/1). The original task lived in a local `.hive-state/` branch, so this guide quotes the idea text and links to the replay artefacts committed in this repo.

## Prerequisites

You need Ruby 3.4, git >= 2.40, `claude` authenticated, `codex` installed for the default execute agent, `gh` authenticated, and a git checkout you can modify. OpenCode is optional and requires `opencode` 1.18.16 or newer. Released native installations also use `cosign` to authenticate the managed Hive web bundle. The commands below use `~/Dev/xbookmark`; substitute your own project path and project name when running against another repo.

## Step 1 - Install

```bash
git clone https://github.com/ivankuznetsov/hive ~/Dev/hive && cd ~/Dev/hive && bundle install && mkdir -p ~/.local/bin && ln -sf ~/Dev/hive/bin/hive ~/.local/bin/hive
```

If `~/.local/bin` is not on your `PATH`, put the symlink in a directory that is before running the next step. The `-sf` form will overwrite an existing `hive` at the target path, so check `command -v hive` first if you already have one installed.

```bash
hive --version
hive setup
```

On supported Linux and macOS hosts, setup installs and starts the per-user
daemon and Hive web services and reports the loopback URL plus installed,
enabled, running, and ready state. It never creates LAN/public binding or
Tailscale exposure. Use `hive setup --no-service` to keep Hive web
foreground-only, `hive web` to run it in the foreground, and
`hive web status --json` for read-only structured state. Windows users should
use the native path under WSL with systemd enabled, or choose
[Hivebox](../packaging/docker/README.md).

## Step 2 - Attach Hive To A Project

```bash
cd ~/Dev/xbookmark
hive init .
```

`hive init` creates `.hive-state/` as a worktree of the orphan `hive/state` branch, registers the project in `~/Dev/hive/config.yml`, and scaffolds the stage folders. Read the storage details in [docs/architecture.md#storage-layout](architecture.md#storage-layout).

## Optional OpenCode Profile

OpenCode is registered everywhere Hive accepts an agent profile but remains
entirely opt-in: no default stage, reviewer council, or fallback selects it.
Install OpenCode 1.18.16 or newer and configure the provider credential you
intend to use. `opencode auth login` writes OpenCode's own auth file; automation
may instead name one credential environment variable in project config. Hive
never accepts the credential value in YAML.

Create an explicit, non-secret provider definition in the project, for
example `.hive/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "anthropic": {
      "npm": "@ai-sdk/anthropic"
    }
  }
}
```

Then add the typed profile and route settings to `.hive-state/config.yml`.
Replace the example route and credential variable name with the exact local
provider/model you intend to run:

```yaml
agents:
  opencode:
    config_path: .hive/opencode.json
    credential_env: [ANTHROPIC_API_KEY]
    plugins:
      - compound-engineering@git+https://github.com/EveryInc/compound-engineering-plugin.git#compound-engineering-v3.21.4
    isolation: hermetic

execute:
  agent: opencode
  permissions:
    preset: scoped
    tools: [Read, Write, Edit]

models:
  execute_implementation:
    model: anthropic/claude-sonnet-4-5
    effort: high
```

OpenCode routes are nested values inside the Hive `opencode` profile. They
must be full `provider/model` values; a different configured provider never
satisfies the request. A top-level exact `model` in the selected OpenCode JSON
may be used as the explicit default when the role has no `models.*.model`.
Faithful effort values render as OpenCode variants only after the local route
probe proves that variant exists.

OpenCode does not accept Hive's default `yolo` stage permission. Use
`read-only` or a scoped policy. Read-only denies edits, shell, unsafe tools,
and external writes. Scoped `Write`/`Edit` enables the generated
workspace-write policy over Hive's resolved working/write roots. Qualified
rules such as `Bash(git*)` opt into only the named OpenCode shell patterns;
bare `Bash` remains invalid, while `Bash(*)` deliberately grants the full
shell with the Hive OS user's authority. Hive redirects OpenCode config, data, cache, and
state into a private per-invocation root, ignores ambient project/global
configuration, forwards only the named credential source, and removes the
overlay after every lifecycle outcome. This is application-level enforcement,
not an OS/container boundary; use Hivebox for hostile-code containment.

Skill-bearing roles additionally require the native Compound Engineering
OpenCode plugin. Preview and apply its pinned `3.21.4` entry with:

```bash
hive setup-agents --agent opencode \
  --skill ce-plan ce-brainstorm ce-code-review ce-test-browser
hive doctor
```

Setup previews the selected OpenCode config change and asks once before its
atomic write. Normal task execution never mutates that source config. A
missing/stale plugin or a higher-precedence project/user CE skill that shadows
the selected plugin fails readiness before any model process starts.

`hive status --json` keeps the Hive provider as `opencode`, retains the
requested nested route, and appends sanitized-export-observed backend/model,
resolution status, outcome, and nullable usage after an implementation
attempt. A requested alias is never copied into the actual field without
export evidence.

## Step 3 - Capture The Idea

```bash
hive new xbookmark "I want to create a service that will connect to my X account and collect all the bookmarks, then use llm-wiki to create a knowledge graph from them."
```

The new task is now in `1-inbox/<slug>/idea.md`. Hive stores the text you typed verbatim, typos and all.

> What xbookmark actually had: the original idea.md (sampled in [docs/assets/xbookmark-walkthrough.txt](assets/xbookmark-walkthrough.txt) since it lives on xbookmark's local `hive/state` branch) looked like this, with the typo `conenct` preserved from the original prompt:
>
> ```yaml
> slug: i-want-to-create-a-260504-1253
> created_at: 2026-05-04T10:50:09Z
> original_text: |
>   I want to create a service that will conenct to my X (twitter) account and collect all the bookmarks...
> ```

## Step 4 - Watch Brainstorm Work

```bash
hive brainstorm <slug>
```

Hive promotes the task to `2-brainstorm/`, runs the configured planning agent, and writes `brainstorm.md`. When the file ends with `<!-- WAITING -->`, answer the questions inline and run the same command again:

```bash
$EDITOR .hive-state/stages/2-brainstorm/<slug>/brainstorm.md
hive brainstorm <slug> --from 2-brainstorm
```

`--from <stage>` is the retry-safety assertion explained in [docs/architecture.md#markers-and-idempotency](architecture.md#markers-and-idempotency); it is optional when you run a stage by hand.

When brainstorm is complete, the state file ends with `<!-- COMPLETE -->`.

## Step 5 - Promote To Plan

```bash
hive plan <slug> --from 2-brainstorm
```

Hive moves the task to `3-plan/`, writes `plan.md`, and pauses for edits if the plan ends with `<!-- WAITING -->`. From there the same promote-or-run pattern carries the task through `develop`, `open-pr`, `review`, `finalize`, and `archive`.

## What Just Happened

`hive new` wrote an `idea.md` file. `hive brainstorm` and `hive plan` moved the task directory between stage folders and ran the stage agents. The current marker at the bottom of each stage file tells Hive whether the next action is human input, another run, or promotion to the next stage.

When the task reaches execute, Hive durably captures its concrete provider and model before spawning the implementation process. Later PR-opening and repair stages follow that owner automatically unless you explicitly configure a stage override. Run `hive status --json` for full provenance, or press `I` on the task in `hive tui` to inspect execute, PR-opening, review-fix, and CI-fix ownership without changing task state.

## Artefacts

- [docs/assets/xbookmark-walkthrough.txt](assets/xbookmark-walkthrough.txt) replays the completed dogfood task.
- [docs/assets/xbookmark-state-tree.txt](assets/xbookmark-state-tree.txt) shows a mid-run `.hive-state/` layout (the task is paused in `3-plan/` to pair with Step 5 above).
- [docs/recipes.md#xbookmark-end-to-end](recipes.md#xbookmark-end-to-end) expands the same example through PR and archive.

Choose Hivebox when you need container isolation, multiple local instances,
containment for untrusted agents, or a reproducible server/NAS deployment. Its
complete container guide is [packaging/docker/README.md](../packaging/docker/README.md).

Next, read [docs/concepts.md](concepts.md), [docs/cli.md](cli.md), or [docs/recipes.md](recipes.md).
