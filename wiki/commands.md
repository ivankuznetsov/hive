---
title: Interaction Surface
type: commands
source: bin/hive, bin/hv, bin/hive-e2e, lib/hive/cli.rb, lib/hive/commands/, skills/hive/, lib/hive/agent_skills/, config/agent-skills.yml, lib/hive/web/, web/, public/, hive.gemspec, packaging/, .github/workflows/{live-agent-skills,release}.yml, openclaw/skills/hive/SKILL.md, openclaw/README.md
created: 2026-05-14
updated: 2026-07-22
tags: [commands, api, skills, agents, operational, provisioning]
---

**TLDR**: Hive's external interaction surface is the Thor CLI (`hive` plus the
`hv` fallback launcher), the opt-in e2e harness, the Hive web command/routes
documented in [[commands/web]], `hive connect screenote` as the Screenote OAuth
setup surface for artifacts MCP uploads, `hive bench submit` as the hive-bench
corpus producer,
`hive pairing` as the Telegram first-contact approval surface, the read-only
agent-first `hive status --operational --json`, bounded `hive watch`, closed
`hive act`, the `hive doctor` / consent-safe setup split for one canonical Hive
operating skill projected to OpenClaw, Claude, Codex, and Pi, and the single
ClawHub `hive-cli` listing whose installed slash command is `/hive`.
The Ruby command/API contract lives in [[cli]] and the
per-command pages. OpenClaw does not add a second runtime and does not publish
one ClawHub listing per Hive verb.

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
- `packaging/docker/Dockerfile`
- `packaging/docker/entrypoint.sh`
- `packaging/docker/install-box.sh`
- `packaging/docker/install-box.ps1`
- `packaging/docker/README.md`
- `openclaw/skills/hive/SKILL.md`
- `openclaw/README.md`

## Surfaces

### Thor CLI

`bin/hive` loads `Hive::CLI` and exposes the public command set documented in
[[cli]] and `wiki/commands/*`. The CLI includes workflow verbs (`new`,
`brainstorm`, `plan`, `develop`, `open-pr`, `review`, `artifacts`, `finalize`,
`archive`), the `hive review --pr` overlay for ad-hoc review of an existing
GitHub PR, project workflow authoring via [[commands/workflow]], daemon/bot/babysitter
lifecycle commands, diagnostics, markers, findings, metrics, update/uninstall,
registry maintenance, Screenote connect/disconnect, the `hive bench submit`
corpus-submission producer,
the [[commands/pairing]] Telegram pairing approval surface,
[[commands/refactor-patrol]] as the architecture refactor thesis scanner (only
its legacy on-demand v1 mode is reporting-only; merged-PR v2 can take separately
authorized actions), and
[[commands/doctor]] read-only managed health reporting,
[[commands/setup-agents]] consent-safe native provisioning,
`--json` envelopes where the command page says they exist.
The default human `hive status` is the concise operational projection;
`--full` retains the detailed table, bare `--json` retains the complete v6
graph, and `--operational --json` selects the additive agent document.
[[commands/watch]] emits bounded semantic JSON Lines without shell polling.
`hive act` accepts only a fresh observation token for the one closed routine
workflow-advance action and recomputes the verb under the task lock.
The wrapper also normalizes command-local help before Thor dispatch:
`hive <cmd> --help`, `hive <cmd> -h`, and option-bearing forms such as
`hive approve --from 2-brainstorm --help` are routed to `hive help <cmd>`
instead of being treated as partially-valid command invocations.
Wrapper-level JSON booleans are normalized with the same exact grammar Thor
uses for boolean options. Leading `--json`, `--json=true`/`TRUE`/`t`/`T`, and
false forms such as `--no-json`, `--skip-json`, or `--json=false` move behind
the command before dispatch; unsupported assignments such as `--json=1` or
`--json=yes` fail as usage errors before the assigned value can become a
command argument or task target. `hive new` is the wrapper-level text-tail
exception: after `hive new PROJECT`, later `--help`, `-h`, or malformed
`--json=...` tokens are treated as literal task text, with `bin/hive` inserting
`--` before the tail so Thor leaves the idea text alone. Wrapper-owned usage
errors use the last recognized JSON boolean flag, so `--json --no-json` and
`--json --json=false` choose human prose instead of an error envelope. When the
final recognized JSON flag is truthy, pre-dispatch Thor usage errors listed in
`JSON_USAGE_ERROR_CONTRACTS` emit command-shaped JSON before stderr, including
unversioned `hive-setup` usage failures and Screenote connect/disconnect
missing-`SERVICE` failures.

After dispatch, commands whose published failures use the common
`Hive::Schemas::ErrorEnvelope` shape route through
`Hive::Schemas::EnvelopeEmitter`. The mixin owns exception normalization,
single-document stdout guarding, schema construction, and closed-pipe handling;
commands supply only their schema, error-kind mapping, and optional fields.
This covers approve, findings inspection/toggles, marker clearing, run, workflow
stage actions, status/diagnose, and the existing forget/prune/daemon/drop/ad-hoc
review producers. Commands with injected output streams, variant schema routing,
or deliberately different published fields retain dedicated emitters rather
than changing their wire contracts merely to share implementation.

`bin/hv` is the Apache Hive collision fallback entrypoint. It probes only the
owned Hive CLI locations and `HIVE_BIN_OVERRIDE`; it intentionally does not
fall through to common Apache Hive paths. See [[operating]] for install-channel
behavior.

`hive bench submit SLUG` is a CLI-only bridge from completed Hive tasks to the
separate hive-bench corpus. It resolves a `9-done` task from registered
projects, runs a local secret-token preflight, delegates extraction to
hive-bench's checkout-local `harness/extract.rb`, then opens a GitHub PR from
the hive-bench checkout. See [[commands/bench-submit]].

`hive setup` is the local workstation provisioning bridge for installs that
`hive setup` is the normal native workstation provisioning bridge: it first
previews and provisions the bundled Hive operating skill for supported agents,
then emits a `hive-setup.v1` phase report, installs/repairs Hive-owned QMD and
authenticated managed web bundle assets, installs the daemon service, enrolls
the current project unless disabled, and installs/starts/probes the separate
loopback Hive web service by default. One interactive confirmation covers the
run; JSON/non-TTY requires `--yes` or performs no mutation. `--no-service` opts
out of web-service mutation while leaving other approved setup work enabled;
`--no-bootstrap` is diagnose-only. See
[[commands/setup]].

`hive pairing` lists and approves Telegram pairing requests minted by unknown
DM chats that send `/start` while `bot.pairing_enabled: true`. Approval appends
the chat id to the global bot allowlist, requests a live bot reload, and queues
an approval DM for the running bot. See [[commands/pairing]] and [[modules/bot]].

`hive connect screenote` and `hive disconnect screenote` manage the operator's
Screenote OAuth credential for MCP-backed artifact uploads. The connect flow
uses loopback auth-code + PKCE, lists projects through Screenote MCP, and
persists the selected default project in `screenote.json`; disconnect revokes
and clears it. See [[commands/screenote]].

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
`/hive wiki compile-log --check`. The patrol section distinguishes subscription
use from additional payment, documents the higher architecture allowance plus
shared daily ceiling, and hands exact token-total inspection to the human-only
TUI. `setup-agents` uses a consent-required `--json` preview followed by an
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
claim on an ownerless box. Production Action Cable accepts same-origin-as-host,
with `web.origin` / `HIVE_WEB_ORIGIN` only as an extra allow for split-origin
deploys. Task Drop is deliberately not daemon-queued: the web handler calls
`Task#drop!`, which runs `Commands::Drop` in-process with the
rendered `from` stage as a stale-page guard. Repo setup clones through `gh`,
normalizes GitHub SSH origins to https, and relies on the Docker image's
`gh auth git-credential` helper for GitHub push auth; the Agents page now starts
the `gh auth login` PTY relay for that credential. Docker packaging adds the
`hivebox-entrypoint` executable, which creates the `/data` XDG/home/repo
directories and then runs `Hive::Web::Supervisor` unless custom argv is passed,
and `packaging/docker/install-box.{sh,ps1}`, the one-command install entrypoints
for `curl -fsSL https://hivecli.sh/box | sh` and
`irm https://hivecli.sh/box.ps1 | iex`. Both pull
`ghcr.io/ivankuznetsov/hivebox:latest` by default, start a named container,
mount persistent data, and print the local URL; the PowerShell script is the
native Windows shape for Docker Desktop hosts where `sh` or MSYS path conversion
would be the wrong interface. The release workflow publishes versioned and
`latest` multi-arch hivebox images to GHCR after `release-finalize`. The gem
packages the gem metadata required for the managed app's installed-root path
dependency; the Rails source remains in the authenticated versioned release
bundle. The app also ships in the Hivebox image at `/app/web` or runs from a
source checkout.

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
