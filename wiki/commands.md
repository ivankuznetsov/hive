---
title: Interaction Surface
type: commands
source: bin/hive, bin/hv, bin/hive-e2e, lib/hive/cli.rb, lib/hive/commands/, skills/hive/, lib/hive/agent_skills/, config/agent-skills.yml, lib/hive/web/, web/, public/, hive.gemspec, packaging/, .github/workflows/{live-agent-skills,release}.yml, openclaw/skills/hive/SKILL.md, openclaw/README.md
created: 2026-05-14
updated: 2026-11-07
tags: [commands, api, skills, agents, operational, provisioning]
---

**TLDR**: [docs/cli.md](../docs/cli.md) is the single authoritative public CLI reference for every visible `bin/hive` command, option, JSON/JSON-Lines/text contract, context rule, and exit code. This page orients Hive's external interaction surfaces (Thor CLI via `hive`/`hv`, native `hive setup` and Hive Web, OpenClaw/ClawHub skill projection, and the opt-in `bin/hive-e2e` harness). [[cli]] maps commands to their internal Wiki architecture pages (`wiki/commands/*` and `wiki/modules/*`), which retain controller, storage, and subsystem architecture rather than competing public CLI contracts. OpenClaw does not add a second runtime and does not publish one ClawHub listing per Hive verb.

## Source Files

- `bin/hive`
- `bin/hv`
- `bin/hive-e2e`
- `lib/hive/cli.rb`
- `lib/hive/commands/adhoc_review.rb`
- `lib/hive/commands/connect.rb`
- `lib/hive/commands/disconnect.rb`
- `lib/hive/commands/bench_submit.rb`
- `lib/hive/commands/pairing.rb`
- `lib/hive/commands/setup_agents.rb`
- `lib/hive/commands/watch.rb`
- `lib/hive/commands/act.rb`
- `lib/hive/operational_status.rb`
- `lib/hive/operational_action.rb`
- `skills/hive/`
- `lib/hive/agent_skills/**/*.rb`
- `config/agent-skills.yml`
- `lib/hive/web/**/*.rb`
- `web/app/views/**`
- `web/app/assets/**`
- `hive.gemspec`
- `.github/workflows/release.yml`
- `.github/workflows/live-agent-skills.yml`
- `openclaw/skills/hive/SKILL.md`
- `openclaw/README.md`

## Surfaces

### Thor CLI

`bin/hive` loads `Hive::CLI` and exposes the public command surface documented authoritatively in [docs/cli.md](../docs/cli.md); internal entry-point architecture and per-command implementation targets are indexed in [[cli]]. Key surface groups include:

- Workflow verbs (`new`, `brainstorm`, `plan`, `develop`, `open-pr`, `review`, `artifacts`, `finalize`, `archive`, `decide`) and ad-hoc PR review (`hive review --pr`), plus project workflow and module management ([[commands/workflow]], [[commands/module]]).
- Native workstation provisioning (`hive setup`, [[commands/setup]]), managed skill inspection/provisioning ([[commands/doctor]], [[commands/setup-agents]]), and loopback Hive web management ([[commands/web]]).
- Agent-first observation and control (`status`, `task`, `watch`, `act`, `answer`, `approve`, `operation`), local/remote context management ([[commands/context]], [[commands/token]], [[remote-access]]), and daemon/bot/babysitter/patrol operations.
- Internal shared infrastructure: `Hive::CliArgvPolicy` normalizes wrapper help/boolean/option-lifting grammar before Thor dispatch, `Hive::CliUsageContracts` preserves pre-dispatch structured usage contracts, `Hive::Schemas::EnvelopeEmitter` centralizes post-dispatch envelope framing, and `bin/hv` provides the Apache Hive collision fallback launcher (see [[cli]] and [[operating]]).

### OpenClaw / ClawHub

`skills/hive/` is the canonical operating policy. `openclaw/skills/hive/` is
its generated OpenClaw projection and the only tree published through ClawHub.
The ClawHub slug is `hive-cli`, installation uses `openclaw skills install
@ivankuznetsov/hive-cli`, the public listing is
`https://clawhub.ai/ivankuznetsov/skills/hive-cli`, and the installed slash
command is `/hive`. Claude
receives `/hive`, Codex `$hive`, and Pi `/skill:hive` from the same canonical
digest through setup-agents.

The version comes from `skills/hive/skill.json`; every projection carries the
skill version, canonical digest, Hive version, native invocation, and exact
file digests. `/hive setup`, `/hive install`, and `/hive bootstrap` enter the
guided setup flow: verify/install the CLI, run strict `hive`/`hv` detection,
provision supported skills with explicit consent, and use
`hive setup --no-init --yes --json` only after approval. Enrollment remains a
separate `hive init .` in the user's real terminal so Hive can disclose its
defaults and ask for confirmation. Package-manager confirmation is preserved;
the skill does not use unattended Arch install flags. The setup report includes
the loopback URL plus distinct Hive web installed, enabled, running, and ready
state alongside daemon setup.

For normal use, the slash-command text after `/hive` is treated as arguments
for the detected Hive CLI binary. Examples in the skill include
`/hive status --operational --json`, `/hive watch <project>:<slug>
--json-lines`, `/hive new . "build this feature"`, `/hive plan
<task-slug>`, `/hive develop <task-slug>`, `/hive review <task-slug>`,
`/hive web status --json`, foreground `/hive web`, `/hive tui`, `/hive
setup-agents`, reviewed Honeycomb workflow
lifecycle commands, ordinary and architecture patrol, digest/bench, and
`/hive wiki compile-log --check`. The patrol section documents one high
per-agent runaway fuse, telemetry-only usage, and exact token-total inspection
through the human-only TUI. `setup-agents` uses a consent-required `--json` preview followed by an
approved `--yes --json` execution; Honeycomb install/update/remove use their
supported `--dry-run --json` previews, with permission escalation approved
separately. Patrol and architecture-patrol dry-runs remain consent-gated because
they launch subscription-backed agents. The skill tells agents to pass
arguments safely, prefer `--json` for inspection, preserve daemon auto-advance
only inside previously approved enrollment, and confirm before persistent,
destructive, foreground, publishing, or outbound actions.
It explicitly forbids patching installed Hive files or writing service-manager
overrides and instead routes repair through Hive-native diagnose/consent flows.

OpenClaw does not introduce Ruby routes, HTTP handlers, controllers, resolvers,
or new executable entrypoints. It is an agent-facing wrapper over the existing
CLI. `hive doctor` checks OpenClaw inventory/provenance read-only; only
OpenClaw/ClawHub installs or updates that projection. The tag workflow's
offline `candidate-gate` verifies the exact four-platform skill archive before
publication without provider credentials. The protected live-agent-skills
workflow remains an optional authenticated diagnostic of native discovery/use.

### Hive web

`hive web` boots the shared Rails 8 + Turbo app from `web/` or the managed
version-stamped bundle (see [[commands/web]]): it derives SECRET_KEY_BASE from
the persisted session secret, keeps the solid-stack sqlite under state_home,
runs db:prepare, and execs `bin/rails server`. The web app reuses the same status, approval, daemon-queue,
task-drop, agent-auth, repo, and Telegram setup contracts as the
CLI/bot/daemon stack; it does not introduce a separate workflow engine. GitHub
device-flow auth can either use a pre-pinned `web.github.owner` or first-login
claim on an ownerless instance. Production Action Cable accepts same-origin-as-host,
with `web.origin` / `HIVE_WEB_ORIGIN` only as an extra allow for split-origin
deploys. Task Drop is deliberately not daemon-queued: the web handler calls
`Task#drop!`, which runs `Commands::Drop` in-process with the
rendered `from` stage as a stale-page guard. Repo setup clones through `gh`,
normalizes GitHub SSH origins to https so pushes use `gh`-supplied https
credentials; the Agents page starts the `gh auth login` PTY relay for that
credential. The gem packages the gem metadata required for the managed app's
installed-root path dependency; the Rails source remains in the authenticated
versioned release bundle, or runs from a source checkout. The Hivebox Docker
distribution (image, one-command installers, container supervisor) was removed
by ADR-055.

### E2E Harness

`bin/hive-e2e` is the opt-in outer test harness for scenario-driven,
subprocess-level verification. It is documented in [[e2e]] rather than treated
as an end-user workflow command. It mirrors the main wrapper's entrypoint
conventions for top-level `--version`, command-local help, and wrapper-level
JSON boolean grammar, so `bin/hive-e2e run --filter tui --help` prints the
`run` usage instead of selecting scenarios or running preflight checks, while
`bin/hive-e2e --json --help run` / `--json -h run` drop the now-irrelevant JSON
flag and render human `run` help with exit `0`. Non-command help trailers such
as `--json --help missing` still keep the JSON-envelope contract.
`bin/hive-e2e --json=true list` dispatches to `list` and unsupported
`--json=<value>` assignments fail before the default `run` pattern can consume
the value. Its wrapper-owned usage/preflight/error envelopes also follow the
last recognized JSON boolean flag, matching the main CLI wrapper. Successful
`--json` surfaces are single-document stdout
contracts: `list --json` emits `hive-e2e-scenarios`, and `clean --json` emits
`hive-e2e-clean`.

The replay subcommand stays a config-gated harness action: a missing stored
`repro.sh` and an existing but non-regular or non-executable `repro.sh` both
exit `78`; JSON mode distinguishes them as `missing_repro` and
`unusable_repro`, respectively.

## Backlinks

- [[index]]
- [[cli]]
- [[operating]]
- [[e2e]]
- [[commands/web]]
- [[commands/setup]]
- [[commands/screenote]]

Command boundaries own static usage contracts, argv-dependent variants, extras,
and custom payload builders through `Hive::CliUsageContracts`. The launcher
resolves once after a usage rejection and reuses the exact contract for error
classification and rendering. Missing contracts or failed resolution use human
stderr, empty stdout, and generic usage exit 64. Only resolution failures add the
bounded `[hive.cli] usage_contract_resolution_failed exception=CLASS` diagnostic;
there is no second lookup during rendering.
