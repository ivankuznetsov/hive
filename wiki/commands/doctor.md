---
title: hive doctor
type: command
source: lib/hive/commands/doctor.rb, lib/hive/agent_skills/inspector.rb, lib/hive/skill_check.rb
created: 2026-05-07
updated: 2026-07-10
tags: [command, preflight, skills, tmux, provisioning]
---

**TLDR**: `hive doctor` is the read-only renderer for Hive's shared managed-skill inspector. It derives effective coding stages, named reviewers, browser hooks, and configured agents; combines native CLI inventory with the real filesystem resolver; and emits one evidence-rich row per agent/capability. `--json` is the versioned `hive-doctor.v2` contract. Legacy tmux, QMD, and deprecated-config checks remain separate rows.

## Usage

```bash
hive doctor
hive doctor --json
```

Run from a Hive-initialized project. Doctor never invokes adapters, install
commands, alias writes, or network/model calls.

## Managed target and health model

`Hive::AgentSkills::TargetResolver` derives rows from the effective config,
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

Health precedence is:

1. `conflicting` — a user-owned alias/source or higher-priority shadow wins;
2. `incompatible` — unsupported CLI/package/source or malformed inventory;
3. `unavailable` — agent binary absent (visible, non-blocking);
4. `stale` — an older repairable version line;
5. `missing` — package or runtime probe unresolved;
6. `healthy` — compatible native identity and expected runtime path both match.

Every unresolved managed row carries a scoped remediation such as
`hive setup-agents --agent claude --skill ce-brainstorm`. Conflict messages
name the winning path/owner and state that Hive will not replace it.

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

- `test/unit/agent_skills/inspector_test.rb` covers health precedence, source/version evidence, shadowing, configured homes/binaries, malformed inventory, repeated fresh inspection, and read-only behavior.
- `test/unit/commands/doctor_test.rb` covers human/v2 JSON rendering, legacy rows, remediation, non-blocking unavailable agents, and shared result correspondence.
- `test/unit/skill_check_test.rb` covers exact Claude/Codex/Pi resolution, escaping, Pi jails, and the write-free global npm-root probe.
- `test/integration/init_doctor_preflight_test.rb` covers init delegation and non-mutating flows.

## Backlinks

- [[cli]] · [[commands/init]] · [[commands/setup-agents]]
- [[modules/agent_profile]] · [[testing]]
