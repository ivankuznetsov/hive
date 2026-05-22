---
title: hive doctor
type: command
source: lib/hive/commands/doctor.rb, lib/hive/skill_check.rb
created: 2026-05-07
updated: 2026-05-14
tags: [command, preflight, skills, tmux]
---

**TLDR**: `hive doctor` walks `brainstorm` + `plan` stage configs **and** every entry in `review.reviewers[]`, asking each agent profile to verify its configured skill (e.g. `/plan`, `/llm-wiki:wiki-plan`, `/compound-engineering:ce-brainstorm`, `/ce-code-review`, `/skill:wiki-plan`) actually resolves to an installed slash-command or skill on disk. Prints a status table; `--json` emits a `hive-doctor.v1` envelope. Also runs **non-fatally** at the end of `hive init` as a preflight: missing skills surface as stderr warnings, but `init` exit code is unaffected.

## Usage

```
hive doctor [--json]
```

Run from a hive-initialized project (loads `<project>/.hive-state/config.yml`).

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | All probed skills `:present` or `:not_applicable` |
| 65 | At least one row is `:missing` or `:version_too_old` |
| 78 | `Hive::ConfigError` / `KeyError` / `ArgumentError` while loading config |

## Row kinds

`Doctor#call` builds two row kinds and concatenates them:

- **`kind: "stage"`** — one row per entry in `STAGES = %w[brainstorm plan]`. `label = stage`. Reads `cfg.dig(stage, "agent")` (default `"claude"`) and resolves the skill via `Hive::Config.stage_skill`. Plan defaults are agent-aware: Claude keeps the legacy `/plan` alias, Codex gets `/llm-wiki:wiki-plan`, and Pi gets `/skill:wiki-plan` after profile formatting. A legacy `plan.skill: /plan` config is also mapped to llm-wiki's canonical `wiki-plan` skill for Codex/Pi. The resolved skill is routed through `profile.format_skill_invocation(skill)` before verification.
- **`kind: "reviewer"`** — one row per entry in `cfg.dig("review", "reviewers")`. `label = "6-review/<name>"`. Reads `agent`, `name`, `kind` (default `"agent"`), and `skill`. The bare config skill is formatted through `profile.format_skill_invocation` to obtain the full invocation before passing to `verify_skill`, so the JSON envelope's `skill` field is uniform across stage and reviewer rows.

Reviewer entries with `kind != "agent"` short-circuit to `:not_applicable` with a "kind '<X>' is not 'agent'; doctor only checks agent-kind reviewers" message. **This is the only load-time signal for non-agent kinds** — `Hive::Config.validate_reviewers!` does not validate `kind`; only `Hive::Reviewers.dispatch` does, at run-time.

## Per-agent verifiers (`Hive::SkillCheck::*`)

Encoded as the third return of `AgentProfile.new(skill_verifier:)`:

- **Claude** — for `/<name>`: `<project>/.claude/commands/<name>.md`, `<project>/.claude/skills/<name>/SKILL.md`, `~/.claude/commands/<name>.md`, `~/.claude/skills/<name>/SKILL.md`, plus any installed plugin cache/marketplace skill or command named `<name>`. For `/<plug>:<name>`: cache layout `~/.claude/plugins/cache/<marketplace>/<plug>/<version>/skills/<name>/SKILL.md` AND marketplace source layout `~/.claude/plugins/marketplaces/<marketplace>/plugins/<plug>/skills/<name>/SKILL.md` (plus `commands/`). Glob metacharacters in `<name>` / `<plug>` are escaped via `Hive::SkillCheck.glob_escape` so `/foo*` cannot false-positive against an unrelated `/foobar` plugin cache.
- **Codex** — for `/<name>`: `<project>/.codex/skills/<name>/SKILL.md`, `~/.codex/skills/<name>/SKILL.md`, `~/.codex/skills/.system/<name>/SKILL.md`, plus any installed plugin cache skill named `<name>`. For `/<plug>:<name>`: `~/.codex/plugins/cache/<marketplace>/<plug>/<version>/skills/<name>/SKILL.md`. Codex has no user-level `commands/` directory; install a SKILL.md instead. Same `glob_escape` rule as claude.
- **Pi** — `/skill:<name>` only. The verifier walks (in order):
    1. `~/.pi/agent/skills/` — recursive `**/<name>/SKILL.md` plus root-level `<name>.md`
    2. `~/.agents/skills/` — recursive `**/<name>/SKILL.md` (no root `.md` — cross-agent dirs use SKILL.md only)
    3. `<project>/.pi/skills/` — recursive plus root `<name>.md`
    4. Every ancestor `<dir>/.agents/skills/` walking up from `project_root` until the nearest `.git/` (or filesystem root)
    5. `~/.pi/agent/settings.json` and `<project>/.pi/settings.json` `skills` / `packages` entries — each entry is **jailed** to settings_dir / `$HOME` / project_root (a `~/` or `/` entry that resolves *exactly* to a jail root is rejected as a DoS-shaped scan request)
    6. `npm root -g`, `~/.pi/npm/node_modules/*/skills/`, and `<project>/.pi/npm/node_modules/*/skills/` — recursive
    7. `~/.pi/agent/git/` — bounded prefix scan over 1–4 path levels under the git root (so `<git>/<host>/<user>/<repo>/skills/` is reachable without an unbounded `**` walk)
    8. Every package whose `package.json#pi.skills` declares a path — each such path is jailed to the package root, so a malicious package cannot point `pi.skills` at `../..` or `/`
  
  Anything not in `/skill:<name>` form returns `:not_applicable` with a message explaining the form mismatch. Settings/manifest JSON files that fail to parse are surfaced via the `:missing` install_hint suffix so a stray comment in `settings.json` does not silently disable discovery.

A new agent profile becomes "doctorable" by registering a `Hive::SkillCheck::*` module and passing its `.method(:verify)` into `AgentProfile.new(skill_verifier:)`.

## JSON envelope (`hive-doctor.v1`)

```json
{
  "schema": "hive-doctor.v1",
  "checks": [
    {"kind": "stage", "stage": "brainstorm", "label": "brainstorm", "agent": "claude", "configured_skill": "/compound-engineering:ce-brainstorm", "skill": "/compound-engineering:ce-brainstorm", "status": "present", "message": "..."},
    {"kind": "stage", "stage": "plan", "label": "plan", "agent": "pi", "configured_skill": "/llm-wiki:wiki-plan", "skill": "/skill:wiki-plan", "status": "present", "message": "..."},
    {"kind": "reviewer", "stage": "6-review", "name": "claude-ce-code-review", "label": "6-review/claude-ce-code-review", "agent": "claude", "configured_skill": "ce-code-review", "skill": "/ce-code-review", "status": "missing", "message": "..."}
  ],
  "summary": {"missing": 1, "present": 2, "not_applicable": 0}
}
```

Field history (all additive — schema name stays `v1`):

- 2026-05-07: `kind`, `name`, `label` added on `checks[]`.
- 2026-05-07: `configured_skill` added on `checks[]`. Carries the raw config-supplied value alongside `skill`, which carries the profile-aware formatted invocation. Pi stage rows are the most affected; consumers that need to round-trip back to the operator's config should read `configured_skill`, not `skill`.
- 2026-05-14: plan-stage defaults became agent-aware. Codex and Pi now resolve the llm-wiki `wiki-plan` skill directly instead of requiring a local `plan` alias.

## Init preflight (non-fatal)

After `Hive::Commands::Init#call` finishes its summary, it invokes `run_init_preflight!` which constructs a discard-output `Doctor`, calls `#call`, and emits stderr warnings of the form `[<row-label>/<agent>] <verifier message>` for every `:missing` row. **Init's exit code is unaffected** — install gaps surface but never block bootstrap.

Rescue scope is `StandardError` (with a `Errno::EPIPE` micro-rescue around `warn`); `Interrupt` and `SystemExit` propagate. Unexpected verifier raises produce a "this may be a hive bug, please report" hint so silent swallow is mitigated. `Doctor#rows` (an `attr_reader`) lets the preflight read probe results in-process without re-running the renderer.

## Tests

- `test/unit/commands/doctor_test.rb` — stage rows, reviewer happy path, mixed agents, empty/nil/absent reviewers, non-agent kinds, pi reviewer rows, JSON envelope shape, long-label width, `attr_reader :rows` exposure.
- `test/unit/skill_check_test.rb` — per-agent verifier paths (including pi recursive walks, settings entries, manifest entries, glob-metacharacter rejection).
- `test/integration/init_doctor_preflight_test.rb` — all-green silence, single-missing stderr warning, multi-missing including a reviewer row, init exit-code unchanged, preflight crash → bug-hint warning, config-load error → bug-hint warning.

## Backlinks

- [[cli]] · [[commands/init]]
- [[stages/brainstorm]] · [[stages/plan]] · [[stages/review]]
- [[modules/agent_profile]] · [[modules/config]]
