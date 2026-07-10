---
title: hive setup-agents
type: command
source: config/agent-skills.yml, lib/hive/agent_skills/, lib/hive/commands/setup_agents.rb
created: 2026-07-10
updated: 2026-07-10
tags: [command, agents, skills, provisioning, consent]
---

**TLDR**: `hive setup-agents` provisions unresolved, enabled built-in skills for Claude, Codex, and Pi from the packaged manifest. It prints one immutable aggregate preview, obtains consent once, revalidates state, executes supported native CLI operations without a shell, continues independent work after failures, and runs the same inspector as `hive doctor` again. It never provisions arbitrary custom skills or replaces user-owned conflicts.

## Usage

```bash
hive setup-agents
hive setup-agents --agent claude --skill ce-brainstorm
hive setup-agents --yes
hive setup-agents --yes --json
```

`--agent` and `--skill` are array/repeatable filters over effective managed
targets. Unknown filters and filters that select unmanaged custom skills fail
before mutation. With no filters, setup addresses every unresolved managed
capability in the effective coding configuration.

## Consent and lifecycle

1. Inspect effective targets with `Hive::AgentSkills::Inspector`.
2. Ask the appropriate adapter for pure frozen operation objects, deduplicating
   several capabilities from one package.
3. Preview exact argv arrays, Hive-owned file paths, prerequisites, skips, and
   conflicts.
4. Without `--yes`, require a TTY and an explicit `y`/`yes`. There is one
   prompt. JSON never prompts and requires `--yes` for planned mutation.
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

`config/agent-skills.yml` is the strict, declarative source of truth. It names
package/source/version, per-agent invocation/probe, prerequisites, supported
action tokens, and the Hive-owned Claude `/plan` alias; it cannot contain shell
commands. Current packages are Compound Engineering, llm-wiki, and Claude's PR
Review Toolkit. Compound Engineering capabilities collapse to one package
install but keep individual verification rows.

- Claude uses native marketplace/plugin JSON commands.
- Codex uses native `plugin marketplace` / `plugin` JSON commands so the CLI
  owns config and cache population.
- Pi uses native package list/install/update commands.

All commands execute as argv arrays. Missing CLIs are `unavailable` skips;
Hive does not install or authenticate providers.

## Ownership and failure safety

Codex operations parse only managed ownership keys, snapshot config bytes,
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
operation results, final health, skips, exit code, and classification. Stdout
contains exactly one JSON document; prompts/progress never contaminate it.

## Extension contract

To add a built-in default:

1. declare the capability and per-agent contracts in the manifest;
2. expose the built-in through the runtime config/template constant;
3. add adapter fixtures if new action/provider behavior is needed;
4. pass `manifest_test.rb` default-coverage drift checks;
5. add offline fake-CLI lifecycle coverage and opt-in structured live-load evidence.

Custom workflows/skills absent from the manifest remain user-managed by design.

## Tests

- `test/unit/agent_skills/{manifest,inspector,provisioner}_test.rb`
- `test/unit/agent_skills/adapters/*_test.rb`
- `test/unit/commands/setup_agents_test.rb`
- `test/integration/{agent_skill_adapters,setup_agents}_test.rb`
- `test/smoke/live_agent_skill_resolution_smoke_test.rb` (explicit opt-in, disposable homes)

## Backlinks

- [[commands/doctor]] · [[commands/init]] · [[cli]]
- [[modules/agent_profile]] · [[testing]] · [[gaps]]
