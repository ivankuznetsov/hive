---
title: Hive::AgentProfile + Hive::AgentProfiles
type: module
source: lib/hive/agent_profile.rb, lib/hive/agent_profiles.rb, lib/hive/agent_profiles/{claude,codex,pi}.rb
created: 2026-04-26
updated: 2026-04-26
tags: [agent, profile, registry, architecture]
---

**TLDR**: `Hive::AgentProfile` is a frozen value object describing one CLI's invocation contract (binary path, headless flag, add-dir flag, version requirement, status-detection mode). `Hive::AgentProfiles` is the singleton registry — built-in profiles for `claude`, `codex`, and `pi` auto-register on `require "hive/agent_profiles"`. Stages look up a profile by name (`AgentProfiles.lookup(:claude)`) and pass it to `Stages::Base.spawn_agent`. Replaces the previous claude-only singleton on `Hive::Agent`. References ADR-017 / ADR-018 / ADR-019.

## `Hive::AgentProfile` — value object

Constructor kwargs (every profile freezes after init):

| Kwarg | Purpose |
|-------|---------|
| `name:` | Symbol used by the registry. |
| `bin_default:` | Default binary path (`"claude"`, `"codex"`, `"pi"`). |
| `env_bin_override_key:` | Env var name (`"HIVE_CLAUDE_BIN"` etc.) that overrides `bin_default` when set non-empty. |
| `headless_flag:` | The `-p` / `--prompt` style flag. |
| `permission_skip_flag:` | The CLI's "no-prompt" flag (e.g. `--dangerously-skip-permissions` for claude). |
| `add_dir_flag:` | Optional flag to grant FS access outside cwd; `nil` means the profile cannot extend the sandbox (triggers `warn_isolation_reduced`). |
| `budget_flag:` | Optional `--budget USD` style flag. |
| `output_format_flags:` | Extra flags for headless output formatting (e.g., `--verbose`). |
| `version_flag:` | The version-probe flag (`"--version"`). |
| `skill_syntax_format:` | Format string for skill invocation (`"/%{skill}"`, `"--skill %{skill}"`, …). |
| `status_detection_mode:` | One of `:state_file_marker`, `:exit_code_only`, `:output_file_exists`. |
| `headless_supported:` | Defaults `true`; profiles without headless support raise on `check_version!`. |
| `min_version:` | Required minimum version (semver tuple compare). |
| `preflight:` | Optional `Proc` invoked before each spawn (e.g., `pi` checks `~/.pi/agent/auth.json`). |

### Key methods

| Method | Behavior |
|--------|----------|
| `bin` | Resolved binary path; env override > `bin_default`. |
| `check_version!` | Runs `bin --version`, parses semver, compares against `min_version`. Cached per `(bin, min_version)` pair. Raises `Hive::AgentError` on missing/un-runnable binary, parse failure, or version below minimum. |
| `preflight!` | Calls the user-supplied `preflight:` Proc (if any). May raise `Hive::AgentError`. |

`STATUS_DETECTION_MODES` is the closed enum used by `Hive::Agent#handle_exit` to decide success: `state_file_marker` (claude default — agent writes the marker), `exit_code_only` (CI-fix loops — make the command succeed), `output_file_exists` (reviewer/triage spawns — produce the artifact).

## `Hive::AgentProfiles` — registry

Module-level singleton, mutex-guarded. `register(name, profile)` adds (or replaces) under a symbol key. `lookup(name)` raises `Hive::AgentProfiles::UnknownAgent` (which inherits from `Hive::ConfigError`) if missing. `registered_names` returns the live list — used by `Hive::Config.validate_agent_name!` so config errors list every valid profile.

`reset_for_tests!` clears the registry; per-test setup re-requires `hive/agent_profiles` to re-register the v1 built-ins.

## Built-in profiles

Auto-required from `lib/hive/agent_profiles.rb`:

- `claude` — `--dangerously-skip-permissions`, `--add-dir`, `--budget`, headless via `-p`. Min version `2.1.118`. `:state_file_marker` mode.
- `codex` — `--dangerously-bypass-approvals-and-sandbox`, `--add-dir`, headless via the `exec` subcommand, `--json` output. No native budget flag (hive enforces wall-clock timeout only). Min version `0.125.0`. `:output_file_exists`.
- `pi` — no permission flag, no `--add-dir` (triggers `warn_isolation_reduced` when callers pass `add_dirs:` per ADR-018), preflight checks for `~/.pi/agent/auth.json`. Min version `0.70.2`. `:output_file_exists`.

## Used by

- `Stages::Base.spawn_agent` — calls `profile.check_version!` then `profile.preflight!` before spawning. Honors `add_dir_flag`; logs an isolation-reduced warning when callers pass `add_dirs:` to a profile that lacks the flag.
- `Hive::Agent#build_cmd` — composes the argv from the profile's flags.
- `Hive::Config.validate_role_agent_names!` and `validate_reviewers!` — every `agent:` field in `review.{ci,triage,fix,browser_test}` and `review.reviewers[]` must resolve via `AgentProfiles.lookup`.

## Tests

- `test/unit/agent_profile_test.rb` — version cache, env override, preflight, headless gate.
- `test/unit/agent_profile_modes_test.rb` — `:state_file_marker` / `:exit_code_only` / `:output_file_exists` branching in `Hive::Agent#handle_exit`.
- `test/unit/agent_profiles_test.rb` — registry register / lookup / unknown.
- `test/unit/spawn_agent_test.rb` — preflight ordering, isolation-warning trigger, default-profile fallback.
- `test/unit/pi_preflight_test.rb` — pi's auth.json preflight gate.

## Backlinks

- [[modules/agent]] · [[modules/config]]
- [[stages/review]] · [[architecture]]
- [[decisions]] (ADR-017 / ADR-018 / ADR-019)
