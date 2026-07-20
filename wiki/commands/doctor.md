---
title: hive doctor
type: command
source: skills/hive/, lib/hive/commands/doctor.rb, lib/hive/agent_skills/{inspector,filesystem_inventory}.rb, lib/hive/agent_skills/adapters/openclaw.rb, lib/hive/skill_check.rb
created: 2026-05-07
updated: 2026-07-20
tags: [command, preflight, skills, hive, openclaw, tmux, provisioning]
---

**TLDR**: `hive doctor` is the read-only renderer for Hive's managed-skill
inspector. It always checks Hive's own operating skill for supported Claude,
Codex, and Pi agents, adds capabilities derived from project configuration,
and reads OpenClaw's durable ClawHub provenance without changing it. Durable
filesystem evidence is joined with the real runtime resolver and exact
projection digests; Doctor does not launch supported agent CLIs, because even
nominally read-only upstream commands can initialize user state. `--json` is
the versioned `hive-doctor.v2` contract.
Legacy tmux, QMD, and deprecated-config checks remain separate rows.

## Usage

```bash
hive doctor
hive doctor --json
```

Run from a Hive-initialized project. Doctor reads installed-package registries,
config, cache paths, canonical manifests, and ClawHub origin/lock metadata. It
does not launch Claude, Codex, Pi, or OpenClaw; invoke install/update commands;
write aliases or skills; or call a model. An absent agent binary is an
`unavailable`, non-blocking row. Legacy dependency checks remain bounded and
separate from managed-agent inventory.

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

Doctor retains dependency/warning checks for `tmux >= 3.0` when
`claude.mode: tmux`, managed QMD availability/native ABI failures, exported
Claude API-key warnings in tmux mode, and legacy `brainstorm.runtime` config.
These appear under `checks`, not `managed_skills`.

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

## Init integration

After project creation, `hive init` runs this inspector. Interactive init with
actionable available rows offers to delegate to [[commands/setup-agents]]. A
decline, non-TTY run, or JSON run only prints remediation. Unavailable-only
rows do not prompt, and optional setup failure never rolls back the initialized
project.

## Tests

- `test/unit/agent_skills/inspector_test.rb` covers health precedence,
  source/version evidence, shadowing, configured homes/binaries, native setup
  refresh, and filesystem-only Claude/Codex/Pi inventory with zero runner calls.
- `test/unit/agent_skills/openclaw_test.rb` covers native setup inventory,
  filesystem-only ClawHub provenance, legacy projection evidence, drift, and
  zero-command/no-write behavior.
- `test/unit/commands/doctor_test.rb` covers human/v2 JSON rendering, legacy
  rows, remediation, non-blocking unavailable agents, and byte-identical homes
  even when every available agent runner would mutate if called.
- `test/unit/skill_check_test.rb` covers exact Claude `/hive`, Codex `$hive`,
  and Pi `/skill:hive` resolution, escaping, Pi jails, and the write-free
  global npm-root probe.
- `test/integration/init_doctor_preflight_test.rb` covers init delegation and non-mutating flows.

## Backlinks

- [[cli]] · [[commands/init]] · [[commands/setup-agents]]
- [[modules/agent_profile]] · [[testing]]
