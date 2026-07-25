---
title: hive setup-agents
type: command
source: skills/hive/, config/agent-skills.yml, lib/hive/agent_skills/, lib/hive/commands/setup_agents.rb
created: 2026-07-10
updated: 2026-07-25
tags: [command, agents, skills, hive, canonical, provisioning, consent]
---

**TLDR**: `hive setup-agents` provisions the bundled Hive operating skill for
Claude, Codex, and Pi plus unresolved built-in native capabilities for those
agents and Grok. Grok currently participates through native Compound
Engineering plugin capabilities, not a copied Hive operating-skill projection.
Setup prints one immutable aggregate preview, obtains consent once, revalidates
state, publishes whole skill directories or uses supported native package
operations, and reinspects the result. It never provisions arbitrary custom
skills or replaces user-owned conflicts.

## Usage

```bash
hive setup-agents
hive setup-agents --agent claude --skill ce-brainstorm
hive setup-agents --agent grok --skill ce-code-review
hive setup-agents --yes
hive setup-agents --yes --json
```

`--agent` and `--skill` are array/repeatable filters over effective managed
targets. Unknown filters and filters that select unmanaged custom skills fail
before mutation. Package prerequisites are added recursively after filtering,
so a narrow request cannot omit a required package. A prerequisite that cannot
be inspected, repaired, or proven healthy blocks its dependent operation. With
no filters, setup addresses every unresolved managed capability in the
effective coding configuration plus the bundled `hive` capability for every
agent declared by that bundled package. Filtering to Claude, Codex, or Pi
retains that agent's Hive operating skill. Grok is native-capability-only, so
its targets come from effective stage/reviewer configuration. OpenClaw is
deliberately not a setup target: its native/ClawHub state is diagnosed
read-only and installed through OpenClaw itself.

## Consent and lifecycle

1. Inspect effective targets with `Hive::AgentSkills::Inspector`.
2. Ask the appropriate adapter for pure frozen operation objects, deduplicating
   several capabilities from one package.
3. Preview exact argv arrays, Hive-owned file paths, prerequisites, skips, and
   conflicts.
4. Without `--yes`, require a TTY and an explicit `y`/`yes`. There is one
   prompt. JSON and non-TTY callers without `--yes` are refused before native
   inspection; their typed response has an empty deferred preview and consent
   provenance `json_requires_yes` or `non_tty`.
5. Reinspect and rebuild the fingerprint immediately before execution. A
   changed interactive plan is shown and reconfirmed; `--yes` accepts the
   revalidated plan but never bypasses conflicts.
6. Run dependency-ordered operations. Failure skips only dependents and does
   not stop unrelated packages/agents.
7. Reinspect every targeted row and compute the result from structured
   outcomes plus residual health.

Matching installs yield no operations. Partial-success reruns begin with fresh
inspection and schedule only what remains.

## Manifest and adapters

`skills/hive/` is the canonical, platform-neutral Hive operating policy.
`skill.json` pins its schema, semantic version, and references. Hive renders
deterministic projections with one canonical digest and these native
invocations:

| Platform | Explicit invocation |
|---|---|
| Claude | `/hive` |
| Codex | `$hive` |
| Pi | `/skill:hive` |
| OpenClaw | `/hive` |

The generated OpenClaw tree under `openclaw/skills/hive/` is a checked-in
projection of that same source, not an independent skill. Codex additionally
receives its native `agents/openai.yaml` interface metadata.

`config/agent-skills.yml` is the strict declarative package/provisioning source
of truth. It names package/source/version, per-agent invocation/probe,
prerequisites, supported action tokens, and the Hive-owned Claude `/plan`
alias; it cannot contain shell commands. Current capabilities include the
bundled Hive operating skill, Compound Engineering, llm-wiki, and Claude's PR
Review Toolkit. Compound Engineering capabilities collapse to one package
install but keep individual verification rows.

- Claude uses native marketplace/plugin JSON commands.
- Codex uses native `plugin marketplace` / `plugin` JSON commands so the CLI
  owns config and cache population.
- Pi uses native package list/install/update commands.
- Grok uses native `plugin list`, `inspect`, install-with-trust, enable, and
  update commands. Durable doctor inspection cross-checks
  `installed-plugins/registry.json` with `[plugins] enabled`/`disabled` in
  `config.toml`; an installed but disabled plugin is repaired with
  `grok plugin enable`, not mistaken for a healthy runtime skill.
- The bundled Hive capability for Claude, Codex, and Pi uses
  `DirectoryPublisher` against each agent's private user root. It verifies the
  projection manifest and file digests, stages every file in a private sibling,
  then swaps the whole `skills/hive` directory atomically.

All commands execute as argv arrays in dedicated process groups. A deadline
terminates and reaps the command plus descendants before setup reports a
timeout, so an installer cannot continue mutating after its operation has
failed. Missing CLIs are `unavailable` skips; Hive does not install or
authenticate providers.

## Ownership and failure safety

The bundled publisher refuses symlinked, redirected, group/world-writable, or
foreign destinations. A modified tree is a conflict, not something Hive
silently overwrites. Preview snapshots include path identity and tree digests;
execution revalidates them under an owner-private lock. Stale intact
Hive-managed projections can be replaced as one directory, with rollback
before the commit boundary and orphaned staging/backup directories surfaced as
actionable conflicts.

Every projection includes `.hive-skill.json` with owner, platform, native
invocation, skill version, canonical digest, Hive version, and exact file
digests. Inspector health is based on that provenance and the agent's real
resolver, not merely on a directory name.

Codex package operations parse only managed ownership keys, snapshot config bytes,
digest, and mode, then call the supported CLI. A different source/plugin owner
is `conflicting` and schedules no write. Successful changes must preserve
comments, unrelated TOML keys, and mode. A known torn CLI write can be restored
only if no concurrent user edit occurred; Hive never restores over a changed
digest.

The Claude `/plan` alias is written atomically only when absent or semantically
Hive-owned. A user-authored alias or higher-precedence shadow remains
byte-identical and gets manual remediation. There is no global rollback for
network/auth failures; successful independent installs remain useful.

## Output and exit codes

Operation state (`planned`, `skipped`, `succeeded`, `failed`) is separate from
final health (`healthy`, `missing`, `stale`, `incompatible`, `conflicting`,
`unavailable`).

| Code | Meaning |
|---:|---|
| 0 | All available targeted rows are healthy/no-op; remaining rows are unavailable-only skips. |
| 1 | An operation failed or an actionable conflict/incompatible/residual state remains. |
| 64 | Consent declined, or planned mutation had neither TTY consent nor `--yes`. |
| 78 | Manifest, effective config, or filter invalid. |

`--json` emits `hive-setup-agents.v1`: preview/fingerprint, consent provenance,
operation results, final health, skips, exit code, and classification. An
unconsented unattended response is always exit 64 even when the installation
might already be healthy: Hive deliberately does not launch native discovery
to find out. Stdout contains exactly one JSON document; prompts/progress never
contaminate it.

## Extension contract

To add a built-in default:

1. declare the capability and per-agent contracts in the manifest;
2. expose the built-in through the runtime config/template constant;
3. add adapter fixtures if new action/provider behavior is needed;
4. pass `manifest_test.rb` default-coverage drift checks;
5. add offline fake-CLI lifecycle coverage and opt-in structured live-load evidence.

Custom workflows/skills absent from the manifest remain user-managed by design.

For changes to Hive's own operating policy, edit `skills/hive/`, regenerate
the OpenClaw projection, and pass canonical/projection validation. Do not
hand-edit `openclaw/skills/hive/`.

## Tests

- `test/unit/agent_skills/{manifest,inspector,provisioner}_test.rb`
- `test/unit/agent_skills/{canonical_skill,directory_publisher}_test.rb`
- `test/unit/agent_skills/adapters/*_test.rb`
- `test/unit/commands/setup_agents_test.rb`
- `test/integration/{agent_skill_adapters,setup_agents}_test.rb`
- `test/smoke/live_agent_skill_resolution_smoke_test.rb` (explicit opt-in, disposable homes)
- `test/smoke/live_hive_operating_skill_smoke_test.rb` (four-platform,
  exact-artifact release proof; skips diagnostically outside protected runs)

## Backlinks

- [[commands/doctor]] · [[commands/init]] · [[cli]]
- [[modules/agent_profile]] · [[testing]] · [[gaps]]
