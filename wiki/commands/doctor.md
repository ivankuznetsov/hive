---
title: hive doctor
type: command
source: skills/hive/, lib/hive/commands/doctor.rb, lib/hive/commands/doctor/agent_cli_check.rb, lib/hive/agent_cli_identity.rb, lib/hive/user_service/execution_environment.rb, lib/hive/agent_skills/{inspector,filesystem_inventory}.rb, lib/hive/agent_skills/adapters/openclaw.rb, lib/hive/skill_check.rb, schemas/hive-doctor.v2.json
created: 2026-05-07
updated: 2026-11-03
tags: [command, preflight, skills, hive, openclaw, provisioning]
---

**TLDR**: `hive doctor` diagnoses managed skills and compares configured agent
CLIs between the invoking shell and installed daemon, babysitter, bot and web
services. It always checks Hive's own operating skill for supported Claude,
Codex, and Pi agents, adds capabilities derived from project configuration,
and reads OpenClaw's durable ClawHub provenance without changing it. Durable
filesystem evidence is joined with the real runtime resolver and exact
projection digests; default doctor does not launch agent CLIs, because even
nominally read-only upstream commands can initialize user state. `--json` is
the versioned `hive-doctor.v2` contract.
Legacy Claude auth/config, QMD, and deprecated-config checks remain separate rows. When a
runtime database or cutover manifest exists, Doctor also reports exact SQLite
application/schema/integrity health without creating or migrating anything.

## Usage

```bash
hive doctor
hive doctor --json
hive doctor --probe-agent-versions
```

Run from a Hive-initialized project. Doctor reads installed-package registries,
config, cache paths, canonical manifests, and ClawHub origin/lock metadata. It
does not launch agent CLIs by default; invoke install/update commands;
write aliases or skills; or call a model. An absent agent binary is an
`unavailable`, non-blocking managed-skill row; CLI identity gaps are advisory
warnings. Legacy dependency checks remain bounded and
separate from managed-agent inventory.

## Shell and installed-service CLI identities

Doctor compares every registered profile, including project `agents` overrides,
in the invoking process environment and each installed daemon, babysitter, bot
and web service. The bot's diagnostic refresh can launch a configured diagnosis
profile through `hive status --diagnose`. Creating an idea in web can launch
`hive generate-name` through the new-task flow, selecting the configured execute
profile for display-name generation. Both inherit their spawning service's
environment.
The fixed commands in web's agent-authentication PTY do not run configured
profiles and remain outside profile execution.
Stopped, disabled and unloaded installations remain visible. Only a
proven absent service is omitted. Shell resolution uses the current process's
PATH and environment, without interactive aliases, functions or a login shell.

Rows identify the selection regime: plain spawn uses the first executable on
the child PATH, isolated spawn uses Hive's existing trampoline-skipping
selector before environment scrubbing, and managed spawn requires a prepared
runtime binding. Doctor does not prepare a runtime, so absent binding evidence
is explicitly unknown. A shared shim path with an unknown effective target is
incomplete evidence. Different launch paths, effective targets and known
versions are compared separately, including an explicit older-service verdict.
Shell `0.156.1` versus an npm daemon `0.153.4` is a diagnostic fixture; those
numbers make no claim about model support in either release.

Service rows describe on-disk configuration and available read-only manager
evidence. They do not prove the environment of a running process. Linux
Environment entries, resets, drop-ins and EnvironmentFile sources, or launchd's
named EnvironmentVariables dictionary, supply independent resolution inputs.
Doctor never fills missing service activation variables from the shell or
evaluates unit shell snippets. With no declared WorkingDirectory it models the
invoking project root and labels that cwd inherited. Opaque wrappers and shim
activation that cannot be established from filesystem evidence stay unknown.
For the bot, it also reads Hive's startup `.env` from the reconstructed
configuration location. Existing service values win, including empty values;
only unset resolution keys are added. Location inputs stay private, and the
startup file participates in source freshness checks.
Changed sources or pending reloads warn that a running service may be stale:
reload changed systemd configuration and restart the affected service, then
rerun doctor. Missing process-start evidence remains unknown.

Default version inspection requires provider ownership and a link to the
selected executable:

| Profile | Recognized filesystem evidence |
|---|---|
| Claude | Linked `@anthropic-ai/claude-code` npm manifest, concrete native version target, or matching Homebrew receipt. |
| Codex | Linked `@openai/codex` npm manifest or matching Homebrew receipt. |
| Pi | Linked registered Pi npm package manifest. |
| Grok | Linked `@xai-official/grok` npm manifest or matching `.grok/bin/grok-<version>` installation metadata and canonical symlink. A dynamic bootstrap's effective target remains unknown. |
| OpenCode | Linked `opencode-ai` npm manifest or matching Homebrew receipt. |

Node/Ruby version directories, sandbox paths, arbitrary nearby manifests and
copied standalone binaries do not establish an agent version. Custom profiles
and install methods outside the recognized layouts retain typed reasons such
as `unrecognized_install_layout` or `provider_metadata_mismatch`. When the only
gap is an underivable filesystem version, rows render
`version-uninspected` with a `--probe-agent-versions` hint. Advisory missing,
unknown and divergent identities are warning rows in `hive-doctor.v2` checks;
they do not add exit failures. Managed health failures still exit 65 and
configuration errors still exit 78.

`--probe-agent-versions` explicitly executes version commands under complete
reconstructed contexts. This includes relative configured paths resolved
against the modelling cwd, shared installations and opaque tool-manager shims:
it runs whatever executable that context and selection regime resolve. A
version command can execute launcher/manager code and have side effects. Time,
capture and process-group bounds do not establish executable trust; no
ownership/mode refusal or low-trust classification is added. Incomplete or
stale service contexts are not probed as current complete environments.
Managed skill inventory stays filesystem-only and this flag does not enable
MCP discovery; use `hive mcp import --dry-run` for explicit personal MCP
inventory discovery.

Each version probe has at most 30 seconds including cleanup. All agent probes
share a monotonic 60-second budget including cleanup; remaining work gets the
typed `probe_budget_exhausted` reason while filesystem evidence remains visible.
The manager-read pass has a separate 10-second budget, at most five seconds
per query. Together with the existing 15-second QMD probe, the diagnostic
subprocess allowance is at most 85 seconds, excluding filesystem and rendering
work. Probe output and environment values are not emitted in diagnosis.

To select an intended CLI and enforce its minimum at execution, configure:

```yaml
agents:
  codex:
    bin: /opt/agent-clis/codex
    min_version: "0.156.1"
```

`agents.codex.env_override: PROJECT_CODEX_BIN` optionally names a
project-specific binary environment key. Its nonempty value wins first, then
the profile's retained package override keys, then the configured `bin` (or
profile default when no `bin` is configured). Clear unintended override values
in the relevant shell/service environment when pinning a CLI. Doctor reports
advisory evidence; the existing launch-time minimum-version check remains
authoritative. Updating this project configuration does not itself reload or
restart a service.

## Identity on an attempted run

Doctor models selection without preparing or launching an agent. Actual runs
capture immutable CLI identity after command and child-environment preparation,
including the selection regime, full selected launch path, effective target
when known, and version/evidence or a typed unknown reason. Managed launches
identify the bound host CLI separately from the sandbox launcher and path.

An unsupported-model failure adds the full identity and the
`agents.<name>.bin` / `agents.<name>.min_version` remedy to the existing private,
receipt-correlated attempt log. It also advises selecting a supported model
and checking for a stale CLI. The terminal diagnosis is retained near the end
of the log so the bounded diagnostic tail can show it after lengthy output.
Markers and status carry a compact diagnostic reference and log command:

```bash
hive task TARGET --log
hive task TARGET --project PROJECT --log
```

Use the affected task's ID or slug for `TARGET`. Hive resolves the current
attempt receipt and verifies the log's integrity before rendering its bounded
tail; see [[commands/task]]. Local doctor output and private task logs retain
full non-secret absolute paths. Secret patterns are redacted, and published
attempt evidence continues to replace local paths with `[REDACTED:path]`.
Unsupported-model failures remain operator-required; this diagnosis adds no
hourly retry or provider cooldown, and babysitter still gives up.

## Runtime control-plane diagnosis

Doctor opens no missing database. When SQLite or cutover evidence exists, it
validates the immutable manifest, exact application/schema identity, lineage,
and integrity. A corrupt or identity-mismatched manifest stays a typed failure
even if the database file itself is healthy. An incomplete irreversible
cutover reports `hive runtime status` / `hive runtime resume`; Doctor never
falls back to legacy authority and never offers rollback, restore, or downgrade.

The CLI loads the project through the shared `Hive::Config.load` boundary
before constructing the doctor inspector. Unsupported project root keys
therefore stop the command with exit 78 before any QMD, agent, or skill
probe runs and before a success table/JSON report is emitted. The error names
the config path and every unsupported key. During the reviewers migration
window, a valid root-level `reviewers` value is promoted to
`review.reviewers` with a `hive migrate` warning; an invalid promoted value or
a conflict with an already-authored `review.reviewers` still exits 78 before
probes. This is the same configuration boundary other project commands
receive, not a doctor-only check.

## Managed target and health model

`Hive::AgentSkills::TargetResolver` starts with the bundled `hive` capability
for every supported agent, independent of which agents happen to own a stage.
It then derives rows from the effective config,
including `brainstorm`, `plan`, `review.reviewers`, optional browser testing,
ad-hoc reviewers, and enabled patrol reviewers. Manifest-known built-ins are
managed. Native reviewers and custom skills remain visible but never become
setup operations. When a registered agent has no Hive skill resolver (for
example Grok), an unmanaged custom reviewer remains visible as informational
`unavailable` evidence instead of aborting the whole report; Hive leaves that
skill's installation and resolution to the agent's own tooling.

`Hive::AgentSkills::Inspector` uses
`AgentProfiles.lookup(name, cfg: config)`, so project binary overrides match
real stage execution. It honors `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, and
`PI_CODING_AGENT_DIR`, then applies `Hive::SkillCheck`'s project-before-home
resolution rules. A native inventory claim is insufficient when the runtime
resolver cannot load the declared probe.

The Doctor command owns the ordered summary keys and reaches the inspector
through the supported `Hive::AgentSkills.hive_inspector` facade. Direct Ruby
callers may therefore inject a compatible inspector and request the v2 JSON
summary without relying on a previous command or test to have loaded an
internal skillpack class.

In `native`, `inventory_source: "filesystem"`, `commands: []`, and a null
`cli_version` make that evidence boundary explicit. Setup uses live native
inventory only after consent; Doctor intentionally reports durable installed
state without asking an upstream CLI to bootstrap or refresh it.

Health precedence is:

1. `conflicting` — a user-owned alias/source or higher-priority shadow wins;
2. `incompatible` — unsupported package/source or malformed durable inventory;
3. `unavailable` — agent binary absent (visible, non-blocking);
4. `stale` — an older repairable version line;
5. `missing` — package or runtime probe unresolved;
6. `healthy` — compatible native identity and expected runtime path both match.

Every unresolved managed row carries a scoped remediation such as
`hive setup-agents --agent claude --skill ce-brainstorm`. Conflict messages
name the winning path/owner and state that Hive will not replace it.
OpenCode's exact pinned configured-plugin identity is represented as
`configured:<package>` when the plugin has not materialized a stable on-disk
install root yet. Doctor accepts that identity only when it byte-matches the
native inventory's expected package id; arbitrary configured identities still
fail the expected-source check.

For the bundled capability, `expected` carries distribution `bundled`, skill
version, platform invocation (`/hive` for Claude, `$hive` for Codex,
`/skill:hive` for Pi), canonical digest, Hive version, destination, and exact
file digests. The inspector verifies `.hive-skill.json`, all files, safe path
ownership, and native runtime resolution. A missing projection is `missing`,
an intact older Hive-owned projection is `stale`, and modified/foreign content
or unsafe path ancestry is `conflicting`.

## OpenClaw evidence

With no `--agent`/`--skill` filter, doctor also runs the read-only OpenClaw
adapter. It resolves the configured workspace from `openclaw.json`, verifies
the local `hive-cli` ClawHub origin and workspace lock against `SKILL.md`, and
checks canonical projection provenance while allowing ClawHub-owned metadata
files. It never launches `openclaw` or writes the OpenClaw skill directory.

- Missing: `openclaw skills install @ivankuznetsov/hive-cli`
- Stale: `openclaw skills update @ivankuznetsov/hive-cli`
- Conflicting/incompatible: inspect `openclaw skills info hive --json`; Hive
  will not replace foreign content.

## Legacy rows and exit codes

Doctor retains these legacy rows: a `claude/auth` warning when the shell
exports `ANTHROPIC_API_KEY` or `CLAUDE_API_KEY` (Hive unsets them before
launching Claude, so Claude bills the subscription, not the API key); a
`claude/config` warning when `.hive-state/config.yml` still sets the retired
`claude.mode` key (`Hive::Config.obsolete_claude_mode_key?`; the value is
ignored and the row tells the operator to delete the line); managed QMD
availability/native ABI failures; an unparseable `config.yml` warning; and
`web/environment` alias warnings; and the MCP rows below. Warning rows never
change the exit code.

MCP rows (`Hive::Mcp::DoctorCheck`, stage `mcp`; see [[modules/mcp]]):

| Label | Kind | When |
|---|---|---|
| `mcp/catalog` | warning | the global config is unreadable, so granted servers are skipped at launch |
| `mcp/inherit` | warning | `mcp.inherit_user` is true (isolation off); other MCP rows are skipped |
| `mcp/isolation` | warning | a role runs an agent Hive cannot isolate (Grok, custom profiles) |
| `mcp/grants` | warning | a role whose agent cannot receive granted servers (Pi, Grok) has a non-empty grant |
| `mcp/login` | warning | an OAuth server is granted to an agent with no saved login; names `hive mcp login` |
| `mcp/env` | warning | a granted server references an env var unset in doctor's environment (name only) |
| `mcp/codex-config` | present | `config.toml` settings Hive carries over on every Codex launch |
| `mcp/personal` | warning | personal drift is uninspected by default; names `hive mcp import --dry-run` |
| `mcp/drift` | warning | a catalog entry changed or disappeared at its source when a Ruby caller explicitly supplies discovery evidence |

Ordinary doctor leaves personal discovery disabled in production and tests.
`Hive::Mcp::Discovery` can launch agent commands, so operators use
`hive mcp import --dry-run` to request that separate discovery workflow.
`--probe-agent-versions` does not enable it. All MCP rows appear under `checks`,
not `managed_skills`.

| Code | Meaning |
|---:|---|
| 0 | Every available managed target is healthy; unavailable-only rows are non-blocking. |
| 65 | An available target is missing, stale, incompatible, or conflicting, or a required legacy dependency failed. |
| 78 | Effective config or manifest input is invalid. |

## JSON envelope (`hive-doctor.v2`)

```json
{
  "schema": "hive-doctor.v2",
  "schema_version": 2,
  "managed_skills": [
    {
      "kind": "managed_skill",
      "agent": "claude",
      "capability": "ce-brainstorm",
      "health": "missing",
      "expected": {"package": "compound-engineering@compound-engineering-plugin"},
      "native": {"available": true, "package": null},
      "resolution": {"path": null},
      "remediation": "hive setup-agents --agent claude --skill ce-brainstorm"
    }
  ],
  "checks": [],
  "summary": {"managed": {"missing": 1}, "legacy_failures": 0, "warnings": 0}
}
```

`schemas/hive-doctor.v1.json` remains packaged for pinned consumers, but the
command emits v2. The v2 split prevents managed skill evidence from changing
the meaning of old stage/reviewer check rows.

CLI comparison entries remain in `checks` with `stage: "agent_cli"`,
`label: "agent_cli/<profile>"`, the profile in `agent`, the configured executable
selection in `configured_skill`, and the environment label in `skill`. A complete
match has `kind: "dependency"` / `status: "present"`; drift and incomplete or
uninspected evidence have `kind: "warning"` / `status: "warning"`. Optional
`regime`, `identity`, `comparison` and `execution_context` fields retain the
selection authority, launch/target/version comparisons, configuration sources,
cwd provenance, completeness, and separate running currency. Human messages
also show the full paths, evidence and scoped remedy.

Both the v2 success document and the compact configuration-error document call
`JSON.generate` directly. A serialization failure is not converted into a
text response or fallback JSON document; it propagates as a failed invocation.

## Init integration

After project creation, `hive init` runs the managed-skill inspector with native
commands disabled, in production and tests. Interactive init with
actionable available rows offers to delegate to [[commands/setup-agents]]. A
decline, non-TTY run, or JSON run only prints remediation. Unavailable-only
rows do not prompt, and optional setup failure never rolls back the initialized
project.

## Tests

- `test/unit/agent_skills/inspector_test.rb` covers health precedence,
  source/version evidence, shadowing, configured homes/binaries, native setup
  refresh, and filesystem-only Claude/Codex/Pi inventory with zero runner calls.
- `test/unit/agent_skills/openclaw_test.rb` covers filesystem-only ClawHub
  provenance from workspace and managed roots, legacy projection evidence,
  drift, missing binaries/skills, and an always-empty command audit.
- `test/unit/commands/doctor_test.rb` covers human/v2 JSON rendering, legacy
  dependency rows, control-plane integrity, and corrupt-manifest diagnosis.
  `doctor_managed_skills_test.rb` covers managed remediation,
  non-blocking unavailable agents, OpenClaw ownership, and byte-identical homes
  even when every available agent runner would mutate if called.
  `doctor_web_alias_test.rb` also runs independently and covers injected
  inspectors with human and JSON warning output.
- `test/unit/skill_check_test.rb` covers exact Claude `/hive`, Codex `$hive`,
  and Pi `/skill:hive` resolution, escaping, Pi jails, and the write-free
  global npm-root probe.
- `test/integration/init_doctor_preflight_test.rb` covers init delegation and non-mutating flows.
- `test/integration/doctor_config_validation_test.rb` covers shared root-key failures, exit 78, reviewer migration guidance, and the fail-before-probes boundary.
- `test/unit/agent_cli_identity_test.rb`,
  `test/unit/user_service/execution_environment_test.rb`, and the doctor tests
  cover provider-linked filesystem fixtures, platform-independent service
  reconstruction, whole-command no-agent-launch behavior, explicit probe
  contexts/deadlines, comparison advisories and schema-valid v2 output.

## Backlinks

- [[cli]] · [[commands/init]] · [[commands/setup-agents]]
- [[modules/agent_profile]] · [[testing]]
