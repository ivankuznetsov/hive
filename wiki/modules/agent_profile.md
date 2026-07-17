---
title: Hive::AgentProfile + Hive::AgentProfiles
type: module
source: lib/hive/agent_profile.rb, lib/hive/agent_profiles.rb, lib/hive/agent_profiles/{claude,codex,pi,grok}.rb
created: 2026-04-26
updated: 2026-07-17
tags: [agent, profile, registry, architecture]
---

**TLDR**: `Hive::AgentProfile` is a frozen value object describing one CLI's invocation contract (binary path, prompt delivery, permissions, normalized model/effort translation, concrete default-model discovery, root-confined workspace-write support, opt-in verified CLI capabilities, initial-context admission reserve, version requirement, status detection, usage extraction, and skill verification). `Hive::AgentProfiles` is the singleton registry — built-in profiles for `claude`, `codex`, `pi`, and `grok` auto-register on `require "hive/agent_profiles"`. Stages look up a profile by name (`AgentProfiles.lookup(:claude)`) and pass it to `Stages::Base.spawn_agent`. Replaces the previous claude-only singleton on `Hive::Agent`. References ADR-017 / ADR-018 / ADR-019.

## `Hive::AgentProfile` — value object

Constructor kwargs (every profile freezes after init):

| Kwarg | Purpose |
|-------|---------|
| `name:` | Symbol used by the registry. |
| `bin_default:` | Default binary path (`"claude"`, `"codex"`, `"pi"`, `"grok"`). |
| `env_bin_override_key:` | Env var name (`"HIVE_CLAUDE_BIN"` etc.) that overrides `bin_default` when set non-empty. |
| `headless_flag:` | The `-p` / `--prompt` style flag. |
| `prompt_style:` | `:positional`, `:headless_flag_value`, or `:stdin`; controls where the rendered prompt is delivered. Defaults to `:stdin` for a profile named `codex` (backward compatibility), otherwise `:positional`. |
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
| `usage_extractor:` | Optional callable that parses agent events into input/output/cached counters for [[token-usage]]. Interim events can drive `Hive::Agent::StreamTokenMeter`; terminal-only or unavailable counters still leave spawn/day quotas and wall-clock timeouts as the safety fallback. Missing or unrecognized payloads return nil/zero-fill rather than failing the spawn. |
| `skill_verifier:` | Optional callable used by `verify_skill` for profile-specific skill/slash-command resolution. |
| `workspace_write_flags:` | Optional argv that guarantees a writable workspace confined to the spawn root. An empty value means the profile cannot enforce that boundary. Codex declares `--sandbox workspace-write`, `approval_policy="never"`, ephemeral mode, and user-config/rules suppression. |
| `cli_capabilities:` | Optional map from a named capability to opt-in argv. Capability users must call `require_cli_capability!`; Hive checks that the installed/overridden binary's help advertises every required flag before returning them. Claude declares `safe_mode: ["--safe-mode"]`. |
| `initial_context_tokens:` | Non-negative conservative token reserve for provider-owned context emitted before the first streamed usage event. Defaults to zero; Claude declares 20,000 for patrol admission. |
| `default_model_resolver:` | Optional read-only callable that resolves provider-native configuration to one concrete model; `default`/`inherit` are rejected. |
| `model_argument_builder:` | Optional callable translating a normalized model to discrete native argv. |
| `effort_argument_builder:` | Optional callable translating a normalized effort to discrete native argv; absence means unsupported. |
| `launcher_identity:` | Stable profile/launcher version label stored in implementation identity events. |

### Key methods

| Method | Behavior |
|--------|----------|
| `bin` | Resolved binary path; env override > `bin_default`. |
| `check_version!` | Runs `bin --version` under a bounded process-group probe, parses semver, compares against `min_version`, and caches per `(bin, min_version)` pair. Raises `Hive::AgentError` on missing/un-runnable binary, parse failure, timeout, or version below minimum. Timeout escalates TERM to KILL and reaps the child/readers, so a descendant that inherits stdout cannot strand preflight. |
| `preflight!` | Calls the user-supplied `preflight:` Proc (if any). May raise `Hive::AgentError`. |
| `verify_skill(invocation, project_root: nil)` | Delegates to the profile's `Hive::SkillCheck::*` verifier. Returns `[:present, path] / [:missing, hint] / [:not_applicable, why]`. |
| `format_skill_invocation(skill)` | Renders a configured skill name through the profile's `skill_syntax_format`. Accepts slash-prefixed stage form (`/plan`, `/plug:name`), bare reviewer form (`ce-code-review`), and legacy Compound Engineering namespace form (`/compound-engineering:ce-code-review`). Legacy `compound-engineering:ce-*` inputs normalize to the current bare CE skill before profile formatting, so Claude/Codex render `/ce-*` and Pi renders `/skill:ce-*`. Other slash-prefixed inputs round-trip unchanged for profiles whose syntax is the default `"/%{skill}"`; profiles with a non-default syntax strip the leading `/` and any plugin namespace before formatting. Used uniformly by `Stages::Brainstorm`, `Stages::Plan`, `Reviewers::Agent`, `Stages::Review::BrowserTest`, and `Hive::Commands::Doctor` so the slash invocation that reaches the agent CLI matches doctor's verification target. |
| `logged_in?(name, home: Dir.home)` | Returns whether the profile's CLI-owned credential artifact is present. Setup diagnostics use this alongside API-key env vars so token-authenticated Claude/Codex users are not reported unauthenticated, while an empty config directory such as `CODEX_HOME` alone is not treated as auth. |
| `permission_flags(mode = nil)` | Returns profile-owned permission argv. Ordinary modes preserve the existing Claude behavior. The special cross-profile mode `workspace-write` returns only `workspace_write_flags` and raises if the profile cannot enforce the sandbox. |
| `workspace_write_supported?` | True only when the profile declares non-empty root-confined workspace-write argv. Architecture patrol uses this as a fail-closed auto-fix provider gate. |
| `require_cli_capability!(name)` | Version-checks the resolved binary, probes `<bin> <capability-argv> --help` under the same bounded process-group deadline as version discovery, verifies every option token (arguments such as a `--tools` CSV are not mistaken for flags), caches the result by binary/version/capability/argv, and returns a copy. Missing declarations, flags, binaries, failed help, and timeouts raise `Hive::AgentError`. |
| `concrete_default_model(cfg:, project_root:)` | Resolves and validates a provider-native model without copying credentials or arbitrary CLI configuration into Hive state. |
| `identity_arguments(model:, effort:, pin_model:)` | Returns normalized model/effort observability plus discrete native argv, including requested/effective effort and support. |

`STATUS_DETECTION_MODES` is the closed enum used by `Hive::Agent#handle_exit` to decide success: `state_file_marker` (claude default — agent writes the marker), `exit_code_only` (CI-fix loops — make the command succeed), `output_file_exists` (reviewer/triage spawns — produce the artifact).

## `Hive::AgentProfiles` — registry

Module-level singleton, mutex-guarded. `register(name, profile)` adds (or replaces) under a symbol key. `lookup(name)` raises `Hive::AgentProfiles::UnknownAgent` (which inherits from `Hive::ConfigError`) if missing. `registered_names` returns the live list — used by `Hive::Config.validate_agent_name!` so config errors list every valid profile.

`reset_for_tests!` clears the registry; per-test setup re-requires `hive/agent_profiles` to re-register the v1 built-ins.

## Built-in profiles

Auto-required from `lib/hive/agent_profiles.rb`:

For implementation identity, Claude translates normalized values to `--model <model> --effort <effort>` and Codex to `--model <model> -c model_reasoning_effort=<effort>`. Pi and Grok can resolve and optionally pin a concrete provider-native model but declare effort unsupported. An unsupported effort stays visible as requested while native argv omits it and `effective_effort` remains unset.

- `claude` — default skip flag `--dangerously-skip-permissions`, `--add-dir`, `--max-budget-usd`, headless via `-p`, stream-json output with `--verbose`, Claude skill verifier, interim plus terminal usage extraction, and opt-in verified capabilities for `safe_mode` plus the minimal patrol review/fix contexts. Patrol disables slash commands; review exposes `Read,Grep,Glob,Write`, while fix additionally exposes `Bash,Edit`. The profile reserves 20,000 initial-context tokens for patrol admission. Message-start/delta counters support a true in-flight patrol stop. Min version `2.1.118`. `:state_file_marker` mode. `AgentProfile#permission_flags(mode)` is the single source of truth for permission argv, shared by the headless `Hive::Agent` path and the tmux `Hive::ClaudeLauncher#wrapper_command` path: `bypassPermissions` (and a nil mode) yields `--dangerously-skip-permissions`, any other ordinary Claude mode yields `--permission-mode <mode>`.
- `codex` — `--dangerously-bypass-approvals-and-sandbox`, `--add-dir`, headless via the `exec` subcommand, `--json` output, and a dedicated `workspace_write_flags` bundle (`--sandbox workspace-write`, approval policy `never`, ephemeral execution, and ignored user config/rules) for confined architecture-patrol fixes. Prompts are delivered on stdin with `-` in argv. No native budget flag. Hive consumes usage events when present, but real interim-event coverage remains unverified, so spawn/day quotas and the wall-clock timeout are the provider-independent fallback. Min version `0.125.0`. `:output_file_exists`.
- `pi` — no permission flag, no `--add-dir` (triggers `warn_isolation_reduced` when callers pass `add_dirs:` per ADR-018), preflight checks for `~/.pi/agent/auth.json`. Min version `0.70.2`. `:output_file_exists`.
- `grok` — headless via `-p <prompt>`, `--always-approve`, and `--output-format streaming-json`. Preflight accepts `XAI_API_KEY`, `GROK_CODE_XAI_API_KEY`, an explicit absolute credential file via `GROK_AUTH_PATH`, or `auth.json` under an absolute `GROK_HOME`/the default `~/.grok`; device login is `grok login --device-auth`. The direct path takes precedence over `GROK_HOME`, matching the CLI and allowing one refresh-token/lock domain to be mounted into isolated runners. Hive rejects relative path overrides, even when an API key is present, so its parent preflight and a child spawned in another working directory cannot consume different credential files or state directories. No add-dir or budget flag. Text events are concatenated into `final_message`; unavailable token usage stays nil. Min version `0.2.90`. `:output_file_exists`. Native skill verification is not yet available.

## Used by

- `Stages::Base.spawn_agent` — calls `profile.check_version!` then `profile.preflight!` before spawning. Honors `add_dir_flag`; logs an isolation-reduced warning when callers pass `add_dirs:` to a profile that lacks the flag.
- `Hive::Agent#build_cmd` — composes the argv from the profile's flags.
- `Hive::Patrol::AgentLaunch` — derives initial-context admission headroom, verified minimal patrol capability argv, and the Claude review-turn ceiling.
- `Hive::RefactorPatrol::ReviewAgentRunner` — combines its read-only permission scope with Claude's verified minimal patrol review context before project customizations can run.
- `Hive::RefactorPatrol::Fixer` — accepts only a profile with `workspace_write_supported?` and invokes it through the special `workspace-write` permission mode.
- `Stages::Base.record_usage` — reads each profile's `usage_extractor` output and stores per-spawn rows in `Hive::UsageDB`.
- `Hive::Config.validate_role_agent_names!` and `validate_reviewers!` — every `agent:` field in `review.{ci,triage,fix,browser_test}` and `review.reviewers[]` must resolve via `AgentProfiles.lookup`.

## Tests

- `test/unit/agent_profile_test.rb` — version/capability caches, env override, preflight, process-group timeout cleanup for version/help probes and stdout-inheriting descendants, workspace-write flags, and headless gate.
- `test/unit/agent_profile_modes_test.rb` — `:state_file_marker` / `:exit_code_only` / `:output_file_exists` branching in `Hive::Agent#handle_exit`.
- `test/unit/agent_profiles_test.rb` — registry register / lookup / unknown.
- `test/unit/spawn_agent_test.rb` — preflight ordering, isolation-warning trigger, default-profile fallback.
- `test/unit/pi_preflight_test.rb` — pi's auth.json preflight gate.
- `test/unit/grok_preflight_test.rb` — Grok environment/file auth and usage semantics.

## Backlinks

- [[modules/agent]] · [[modules/config]]
- [[stages/review]] · [[architecture]]
- [[decisions]] (ADR-017 / ADR-018 / ADR-019)
