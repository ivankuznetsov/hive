---
title: Daemon and Patrol Failure Containment - Plan
type: fix
date: 2026-07-16
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# Daemon and Patrol Failure Containment - Plan

## Goal Capsule

Prevent one malformed project configuration from terminating the global Hive daemon, and prevent patrol from spending fix-agent tokens or producing misleading patch metadata when it cannot validate or accurately measure a fix. The user request and the observed July 15 daemon/patrol evidence are authoritative. Stop if the changes require weakening patrol's fail-closed shipping rule or changing benchmark workflow semantics. Execute as a focused Hive bug-fix PR; the shipping workflow owns review, PR creation, and CI.

## Product Contract

### Summary

Hive should isolate bad per-project YAML as a project configuration failure while allowing other projects and active daemon children to continue. A normal patrol run should reject missing validation configuration before any reviewer or fixer agent runs, and each patch record should measure only work created after its isolated worktree was attached.

### Problem Frame

On July 15, `Config.load` leaked `Psych::SyntaxError` from one registered project's `.hive-state/config.yml`. The exception escaped daemon project gates, terminated the systemd service, and caused systemd to kill an active benchmark worker tree. Separately, patrol ran four paid fix agents even though every configured validation command was blank; all four outputs then failed closed and their worktrees were removed. Their diffstats also compared against a stale local default branch even though patrol worktrees started from fresh `origin/main`.

### Requirements

#### Configuration failure containment

- R1. Per-project YAML parse and configuration-read failures must surface as `Hive::ConfigError` with the failing config path and must not escape daemon consumers that already isolate configuration errors.
- R2. Valid per-project configuration behavior and existing validation errors must remain unchanged.

#### Patrol preflight

- R3. A non-dry-run patrol cycle with no nonblank validation command must fail with an actionable configuration error before repository mapping, reviewer agents, fixer agents, or state-watermark mutation.
- R4. Dry-run patrol must remain available without validation commands because it intentionally reviews without fixing or shipping.

#### Patch provenance

- R5. Patrol must capture the isolated branch HEAD immediately before the fix agent runs and use that immutable SHA for change detection and diffstat generation.
- R6. Patch records must expose the captured base SHA alongside the final head SHA so maintainers can audit what the attempt changed.
- R7. Patrol PR creation must continue comparing the completed branch to the repository's default branch; only per-attempt patch validation and reporting use the captured base SHA.

### Acceptance Examples

- AE1. Given malformed `.hive-state/config.yml`, `Config.load` raises `Hive::ConfigError`; `Dispatcher#project_enabled?` treats that project as disabled while the daemon tick continues.
- AE2. Given a normal patrol invocation with all validation commands blank, Hive exits as a configuration error and no reviewer/fixer collaborator is called.
- AE3. Given the same configuration in dry-run mode, patrol maps and reviews features but attempts no fixes.
- AE4. Given stale local `main`, fresh `origin/main`, and a patrol fix based on `origin/main`, the patch diffstat contains only the fix-agent change and records the original worktree HEAD as `base_sha`.

### Scope Boundaries

This PR does not change systemd `KillMode`, move workers into separate scopes, recover benchmark task #7517, configure project-specific patrol test commands, or retain arbitrary validation-failed worktrees. It preserves patrol's rule that unvalidated code never commits or reaches a PR.

## Planning Contract

### Key Technical Decisions

- Wrap `Psych::Exception` and the global loader's configuration-read error set at the per-project `Config.load` boundary. This lets existing daemon and patrol rescues contain malformed or unreadable config files without duplicating low-level rescues.
- Add the validation-command gate in `Commands::Patrol#run_cycle` after config loading and before state setup or agent-backed work. Dry-run bypasses the gate because it cannot ship a patch.
- Capture the worktree's pre-agent `HEAD` in `Patrol::Fixer` and thread it through committed-change detection and patch construction. This measures the attempt itself instead of guessing which mutable default-branch ref the worktree originally used.
- Keep `PrOpener`'s default-branch comparison unchanged because a GitHub PR represents the full branch relative to its target, not only the latest patrol attempt.

### System-Wide Impact

The configuration change affects every command that calls `Config.load`, converting malformed per-project YAML from an internal crash into the documented configuration-error contract. Daemon project gates and patrol scheduling already rescue that contract. Patrol's new preflight changes only non-dry-run behavior when shipping is impossible, saving model quota without reducing review or validation requirements.

## Implementation Units

### U1. Contain malformed per-project YAML

**Goal:** Convert every Psych parser failure and configuration-read failure in a project config into `Hive::ConfigError`.

**Requirements:** R1, R2; AE1.

**Dependencies:** None.

**Files:**

- `lib/hive/config.rb`
- `test/unit/config_test.rb`
- `test/unit/daemon/dispatcher_test.rb`
- `wiki/modules/config.md`

**Approach:** Mirror `load_global_config`'s `Psych::Exception` and configuration-read translations at the per-project loader boundary. Strengthen the real daemon predicate tests so they exercise malformed and unreadable on-disk project configs through `Config.load`, rather than only stubbing a pre-wrapped `ConfigError`.

**Execution note:** Start with parser and daemon-predicate tests that reproduce the leaked exception.

**Patterns to follow:** `Config.load_global_config` error translation and `Dispatcher#project_enabled?`'s existing `Hive::ConfigError` rescue.

**Test scenarios:**

- Covers AE1. A syntactically incomplete project config raises `Hive::ConfigError` containing the config path and “not valid YAML”.
- A Psych disallowed-class payload follows the same configuration-error path.
- A directory-shaped or concurrently removed config follows the path-bearing, unreadable configuration-error path.
- A valid project config still merges defaults and validates normally.
- The real dispatcher predicate returns false, rather than raising, when its registered project has malformed or unreadable YAML.

**Verification:** Focused config and dispatcher tests prove malformed project YAML cannot escape the existing daemon isolation boundary.

### U2. Reject unshippable patrol cycles before agent spend

**Goal:** Stop a normal patrol run before mapping or model invocation when it has no validation command.

**Requirements:** R3, R4; AE2, AE3.

**Dependencies:** None.

**Files:**

- `lib/hive/commands/patrol.rb`
- `lib/hive/patrol/validator.rb`
- `test/unit/patrol/validator_test.rb`
- `test/integration/patrol_command_test.rb`

**Approach:** Expose a single validator predicate for whether any supported command is a nonblank string, and call it from the command preflight before state or reviewer construction. Preserve the validator's existing fail-closed result as a defense-in-depth contract for direct fixer callers.

**Execution note:** Prove that all paid collaborators remain untouched on the error path, then preserve dry-run behavior explicitly.

**Patterns to follow:** `Patrol::Validator#validate` command selection and `Commands::Patrol`'s existing configuration-error JSON envelope.

**Test scenarios:**

- Covers AE2. Blank and whitespace-only command values produce a `Hive::ConfigError` before mapper, reviewer, fixer, or PR opener calls.
- The JSON error envelope reports `error_kind: config` and the standard configuration exit code.
- Covers AE3. Dry-run with no validation commands still maps and reviews, reports zero fixes, and does not open a PR.
- A normal run with at least one nonblank supported command proceeds unchanged.

**Verification:** Validator unit tests and patrol command integration tests demonstrate both the early-stop and dry-run exception.

### U3. Measure patrol patches from the attempt's immutable base

**Goal:** Make patch provenance and diffstats independent of stale or moving local default branches.

**Requirements:** R5, R6, R7; AE4.

**Dependencies:** None.

**Files:**

- `lib/hive/patrol/fixer.rb`
- `test/unit/patrol/fixer_test.rb`
- `wiki/modules/patrol.md`
- `wiki/commands/patrol.md`
- `wiki/log.d/20260716T122216Z-daemon-patrol-resilience.md`

**Approach:** Resolve the isolated worktree HEAD immediately after creation and before calling the fix agent. Pass that SHA to the committed-change check and patch builder, include it in serialized patch records, and generate the attempt diffstat from that SHA. Leave PR body and GitHub comparison behavior untouched.

**Execution note:** Build the regression around a repository whose local default ref is stale relative to the worktree's actual starting commit.

**Patterns to follow:** `Worktree#freshest_base`, the existing `PatchAttempt` value object, and fixer tests that prove the managed checkout remains untouched.

**Test scenarios:**

- Covers AE4. A fix worktree beginning ahead of stale local default records its initial HEAD as `base_sha` and reports only the new fix in `diffstat`.
- An agent that commits its own change is recognized relative to the captured base.
- An agent that makes no changes does not pass merely because the branch differs from stale local default.
- Failed patch records keep `base_sha` when the worktree was created, and use null only when no base could be established.
- PR-opening tests continue to compare the branch against the configured default target.

**Verification:** Focused fixer and PR opener tests prove patch-attempt reporting changed while PR semantics did not.

## Verification Contract

- Run the focused config, daemon dispatcher, patrol validator, patrol command, patrol fixer, and patrol PR opener tests.
- Run the complete Ruby test suite.
- Run RuboCop against changed Ruby files.
- Confirm the wiki log is generated from its fragment rather than editing `wiki/log.md` directly.

## Definition of Done

- Malformed or unreadable project YAML is contained as `Hive::ConfigError` and cannot terminate a daemon tick through the known project gates.
- Non-dry-run patrol refuses missing validation configuration before any model-backed collaborator runs; dry-run remains usable.
- Patch JSON carries immutable base and head SHAs, and its diffstat is scoped to the fix attempt.
- Existing patrol validation and PR fail-closed behavior remains intact.
- Focused and full verification pass, documentation matches behavior, and no abandoned implementation experiments remain in the branch.
