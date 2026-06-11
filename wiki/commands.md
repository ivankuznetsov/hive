---
title: Interaction Surface
type: commands
source: bin/hive, bin/hv, bin/hive-e2e, lib/hive/web/, public/, hive.gemspec, packaging/docker/, openclaw/skills/hive/SKILL.md, openclaw/README.md
created: 2026-05-14
updated: 2026-06-11
tags: [commands, api]
---

**TLDR**: Hive's external interaction surface is the Thor CLI (`hive` plus the
`hv` fallback launcher), the opt-in e2e harness, the hivebox web command/routes
documented in [[commands/web]], and the single ClawHub `hive-cli` OpenClaw skill
whose installed slash command is `/hive`. The Ruby command/API contract lives in
[[cli]] and the per-command pages. OpenClaw does not add a second runtime and
does not publish one ClawHub listing per Hive verb.

## Source Files

- `bin/hive`
- `bin/hv`
- `bin/hive-e2e`
- `lib/hive/web/**/*.rb`
- `web/app/views/**`
- `web/app/assets/**`
- `hive.gemspec`
- `packaging/docker/entrypoint.sh`
- `openclaw/skills/hive/SKILL.md`
- `openclaw/README.md`

## Surfaces

### Thor CLI

`bin/hive` loads `Hive::CLI` and exposes the public command set documented in
[[cli]] and `wiki/commands/*`. The CLI includes workflow verbs (`new`,
`brainstorm`, `plan`, `develop`, `open-pr`, `review`, `artifacts`, `finalize`,
`archive`), daemon/bot/babysitter lifecycle commands, diagnostics, markers,
findings, metrics, update/uninstall, registry maintenance, and `--json`
envelopes where the command page says they exist.
The wrapper also normalizes command-local help before Thor dispatch:
`hive <cmd> --help`, `hive <cmd> -h`, and option-bearing forms such as
`hive approve --from 2-brainstorm --help` are routed to `hive help <cmd>`
instead of being treated as partially-valid command invocations.
Wrapper-level JSON booleans are normalized with the same exact grammar Thor
uses for boolean options. Leading `--json`, `--json=true`/`TRUE`/`t`/`T`, and
false forms such as `--no-json`, `--skip-json`, or `--json=false` move behind
the command before dispatch; unsupported assignments such as `--json=1` or
`--json=yes` fail as usage errors before the assigned value can become a
command argument or task target.

`bin/hv` is the Apache Hive collision fallback entrypoint. It probes only the
owned Hive CLI locations and `HIVE_BIN_OVERRIDE`; it intentionally does not
fall through to common Apache Hive paths. See [[operating]] for install-channel
behavior.

### OpenClaw / ClawHub

`openclaw/skills/hive/SKILL.md` is the only checked-in OpenClaw skill source
published through ClawHub. The ClawHub slug is `hive-cli`, the public listing is
`https://clawhub.ai/ivankuznetsov/hive-cli`, and the installed slash command is
still `/hive` because OpenClaw reads `name: hive` from the skill frontmatter.

The checked-in skill version is `0.1.1`. Its frontmatter `description` is the
public listing/search summary, while the opening markdown body documents the
install and common workflow paths. `/hive setup`, `/hive install`, and
`/hive bootstrap` enter the guided setup flow: verify or install the Hive CLI,
run strict `hive`/`hv` version detection, install/enable the per-user daemon,
and optionally run non-interactive `hive init` for the current repository.

For normal use, the slash-command text after `/hive` is treated as arguments
for the detected Hive CLI binary. Examples in the skill include
`/hive status --json`, `/hive new . "build this feature"`, `/hive plan
<task-slug>`, `/hive develop <task-slug>`, `/hive review <task-slug>`,
`/hive web`, and `/hive wiki compile-log --check`. The skill tells agents to
pass arguments safely rather than interpolate raw user text into a shell string,
to prefer `--json` when structured output is useful, to use `--check` when
verifying a compiled wiki changelog, and to confirm before destructive or
foreground/blocking admin commands.

OpenClaw does not introduce Ruby routes, HTTP handlers, controllers, resolvers,
or new executable entrypoints. It is an agent-facing wrapper over the existing
CLI.

### Hivebox Web

`hive web` boots the hivebox Rails 8 + Turbo app from `web/` (see [[commands/web]]): it derives SECRET_KEY_BASE from the persisted session secret, keeps the solid-stack sqlite under state_home, runs db:prepare, and execs `bin/rails server`.
[[commands/web]]. The web app reuses the same status, approval, daemon-queue,
task-drop, agent-auth, repo, and Telegram setup contracts as the
CLI/bot/daemon stack; it does not introduce a separate workflow engine. Task
Drop is deliberately not daemon-queued: the web handler calls
`Hive::Web::Dispatcher#drop`, which runs `Commands::Drop` in-process with the
rendered `from` stage as a stale-page guard. Repo setup clones through `gh`,
normalizes GitHub SSH origins to https, and relies on the Docker image's
`gh auth git-credential` helper for GitHub push auth. Docker packaging adds the
`hivebox-entrypoint` executable, which creates the `/data` XDG/home/repo
directories and then runs `Hive::Web::Supervisor` unless custom argv is passed.
The gem deliberately does NOT package the web app (gemspec_test pins this); the Rails app ships in the Docker image at /app/web or runs from a source checkout.
`hive web` command has the same renderable UI assets as a source checkout.

### E2E Harness

`bin/hive-e2e` is the opt-in outer test harness for scenario-driven,
subprocess-level verification. It is documented in [[e2e]] rather than treated
as an end-user workflow command. It mirrors the main wrapper's entrypoint
conventions for top-level `--version`, command-local help, and wrapper-level
JSON boolean grammar, so `bin/hive-e2e run --filter tui --help` prints the
`run` usage instead of selecting scenarios or running preflight checks, while
`bin/hive-e2e --json=true list` dispatches to `list` and unsupported
`--json=<value>` assignments fail before the default `run` pattern can consume
the value. Its successful `--json` surfaces are single-document stdout
contracts: `list --json` emits `hive-e2e-scenarios`, and `clean --json` emits
`hive-e2e-clean`.

## Backlinks

- [[index]]
- [[cli]]
- [[operating]]
- [[e2e]]
- [[commands/web]]
