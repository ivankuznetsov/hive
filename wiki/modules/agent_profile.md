---
title: Hive::AgentRuntime + Hive::AgentProfile + Hive::AgentProfiles
type: module
source: lib/hive/agent_runtime.rb, lib/hive/agent_profile.rb, lib/hive/agent_profiles.rb, lib/hive/agent_profiles/{claude,codex,pi,grok}.rb, lib/hive/agent_skills/
created: 2026-04-26
updated: 2026-07-27
tags: [agent, profile, registry, architecture, skills, provisioning, permissions, honeycomb]
---

**TLDR**: `Hive::AgentRuntime` is the provider-neutral, policy-light invocation
boundary. It accepts an immutable `Request`, compiles provider argv/stdin into
a `CompiledInvocation`, returns typed capability/probe evidence, and normalizes
provider output into an `ObservableResult`. `Hive::AgentProfile` remains the
frozen provider adapter and its optional-keyword constructor remains the custom
extension contract. `Hive::AgentProfiles` remains the registry; built-ins for
Claude, Codex, Pi, and Grok load through `require "hive/agent_runtime"`.
Process lifetime, timeouts, workflow selection, retries, artifact acceptance,
and stage success remain in Hive.

## Supported Agent ABI

The supported entry point is:

```ruby
require "hive/agent_runtime"
```

The values crossing this boundary are:

- `AgentRuntime::Request` — provider-neutral intent: prompt, permission mode,
  directories, tool scope, budget hint, model/effort, named capabilities, and
  legacy raw provider arguments.
- `AgentRuntime::CompiledInvocation` — frozen discrete `argv`, optional
  `stdin_data`, provider and launcher identity, and capability evidence.
- `AgentRuntime::CapabilityEvidence` — supported/unsupported capability,
  provider, launcher identity, native arguments, and a bounded redacted
  diagnostic.
- `AgentRuntime::ProbeResult` — version/preflight evidence after the profile's
  bounded checks.
- `AgentRuntime::ObservableResult` — provider-neutral exit, timeout, status,
  normalized usage, final message, and bounded diagnostic.

`compile` never spawns. `prepare!` delegates the version and provider preflight
probes. `require_capability!` is the only supported path for opt-in named CLI
capabilities. Unsupported headless, read-only, workspace-write, required
additional-directory, model, effort, raw-argument, and named-capability
requests fail closed as `AgentRuntime::UnsupportedCapability` with typed
evidence. Probe failures become `AgentRuntime::ProbeError`; other compilation
failures become `AgentRuntime::CompilationError`. Diagnostics are secret
redacted and capped at 512 bytes.

Legacy callers still receive the existing mutable result Hash from
`Hive::Agent#run!`. After status handling, `Agent#observable_result` exposes
the corresponding immutable observation without changing that return
contract.

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
| `budget_flag:` | Optional `--budget USD` style flag. A profile-native flag supplies the run cap; provider protocol parsing determines whether the run ended because that cap was exhausted. |
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
| `read_only_flags:` | Optional argv that guarantees read-only execution. Codex declares `--sandbox read-only` with the same approval, ephemeral, and user-config/rules hardening. |
| `cli_capabilities:` | Optional map from a named capability to opt-in argv. Capability users must call `require_cli_capability!`; Hive checks that the installed/overridden binary's help advertises every required flag before returning them. Claude declares `safe_mode: ["--safe-mode"]`. |
| `initial_context_tokens:` | Non-negative conservative token reserve for provider-owned context emitted before the first streamed usage event. Defaults to zero; Claude declares 20,000 for patrol admission. |
| `default_model_resolver:` | Optional read-only callable that resolves provider-native configuration to one concrete model; `default`/`inherit` are rejected. |
| `model_argument_builder:` | Optional callable translating a normalized model to discrete native argv. |
| `effort_argument_builder:` | Optional callable translating a normalized effort to discrete native argv; absence means unsupported. |
| `routed_model_argument_builder:` / `routed_effort_argument_builder:` | Optional routing-only builders. They default to the identity builders, but let a profile keep legacy identity observability while applying native `default`/`inherit` sentinel behavior to active stage routing. |
| `routed_effort_values:` | Optional profile-native allowlist for effective routed effort. A profile with no routed effort builder rejects every newly routed effort. |
| `routing_argument_placement:` | `:subcommand` by default; `:global` for CLIs such as Codex whose model controls must precede `exec` or `review`. |
| `launcher_identity:` | Stable profile/launcher version label stored in implementation identity events. |
| `policy_capabilities:` | Optional symbols proving which managed-package controls the runner can enforce. Empty preserves custom-profile construction but makes managed admission fail closed. |
| `tool_scope_flags:` | Optional `:allowed` / `:disallowed` native flag map. Omission defaults to empty except for a profile named `claude`, where it preserves the legacy `--allowedTools` / `--disallowedTools` mapping; an explicit empty map opts out. |
| `raw_cli_arguments_supported:` | Explicit opt-in for legacy provider-native argv passthrough. Defaults false; Claude enables it for existing MCP/settings/capability adapters. |

### Key methods

| Method | Behavior |
|--------|----------|
| `bin` | Resolved binary path; env override > `bin_default`. |
| `check_version!` | Runs `bin --version` under a bounded process-group probe, parses semver, compares against `min_version`, and caches per `(bin, min_version)` pair. Raises `Hive::AgentError` on missing/un-runnable binary, parse failure, timeout, or version below minimum. Timeout escalates TERM to KILL and reaps the child/readers, so a descendant that inherits stdout cannot strand preflight. |
| `preflight!` | Calls the user-supplied `preflight:` Proc (if any). May raise `Hive::AgentError`. |
| `verify_skill(invocation, project_root: nil)` | Delegates to the profile's `Hive::SkillCheck::*` verifier. Returns `[:present, path] / [:missing, hint] / [:not_applicable, why]`. |
| `format_skill_invocation(skill)` | Renders a configured skill name through the profile's `skill_syntax_format`. Accepts slash-prefixed stage form (`/plan`, `/plug:name`), bare reviewer form (`ce-code-review`), and legacy Compound Engineering namespace form (`/compound-engineering:ce-code-review`). Legacy `compound-engineering:ce-*` inputs normalize to the current bare CE skill before profile formatting, so Claude/Codex render `/ce-*` and Pi renders `/skill:ce-*`. Other slash-prefixed inputs round-trip unchanged for profiles whose syntax is the default `"/%{skill}"`; profiles with a non-default syntax strip the leading `/` and any plugin namespace before formatting. Used uniformly by `Stages::Brainstorm`, `Stages::Plan`, `Reviewers::Agent`, `Stages::Review::BrowserTest`, and `Hive::Commands::Doctor` so the slash invocation that reaches the agent CLI matches doctor's verification target. |
| `logged_in?(name, home: Dir.home)` | Returns whether the profile's CLI-owned credential artifact is present. Setup diagnostics use this alongside API-key env vars so token-authenticated Claude/Codex users are not reported unauthenticated, while an empty config directory such as `CODEX_HOME` alone is not treated as auth. |
| `permission_flags(mode = nil)` | Returns profile-owned permission argv. Ordinary modes preserve the existing Claude behavior. The special cross-profile modes `workspace-write` and `read-only` return only their declared sandbox argv and raise if the profile cannot enforce the requested boundary. |
| `workspace_write_supported?` | True only when the profile declares non-empty root-confined workspace-write argv. Architecture patrol uses this as a fail-closed auto-fix provider gate. |
| `read_only_supported?` | True only when the profile declares non-empty read-only argv. Architecture discovery uses this for non-Claude profiles. |
| `require_cli_capability!(name)` | Version-checks the resolved binary, probes `<bin> <capability-argv> --help` under the same bounded process-group deadline as version discovery, verifies every option token (arguments such as a `--tools` CSV are not mistaken for flags), caches the result by binary/version/capability/argv, and returns a copy. Missing declarations, flags, binaries, failed help, and timeouts raise `Hive::AgentError`. |
| `concrete_default_model(cfg:, project_root:)` | Resolves and validates a provider-native model without copying credentials or arbitrary CLI configuration into Hive state. Codex discovery reads the top-level TOML `model` assignment and accepts ordinary inline comments. |
| `identity_arguments(model:, effort:, pin_model:)` | Returns normalized model/effort observability plus discrete native argv, including requested/effective effort and support. |
| `validate_routed_control!(control, source:)` | Validates one exact/coarse `ModelRouting::EffectiveControl` against this profile's native model/effort capabilities and vocabulary. |
| `routing_arguments(resolution, source:)` | Atomically validates an active `ModelRouting::Resolution`, renders both routed and inherited effective fields with profile-native sentinel behavior, and returns typed global/subcommand argv. Inactive or unscoped resolutions return nil. |
| `raw_cli_arguments_supported?` | True only for a profile that explicitly accepts the legacy raw argv escape hatch. |

The public routed capability matrix is mirrored in
`docs/notes/headless-agent-cli-matrix.md`: Claude and Codex support model plus
effort, Grok supports model plus effort, and Pi supports routed model only. Codex places routed
controls before `exec`/`review`; Claude uses the same rendered flags in
headless and tmux launches. Unsupported effective controls raise before the
launcher performs work instead of being dropped.

`STATUS_DETECTION_MODES` is the closed enum used by `Hive::Agent#handle_exit` to decide success: `state_file_marker` (claude default — agent writes the marker), `exit_code_only` (CI-fix loops — make the command succeed), `output_file_exists` (reviewer/triage spawns — produce the artifact).

## `Hive::AgentProfiles` — registry

Module-level singleton, mutex-guarded. `register(name, profile)` adds (or replaces) under a symbol key. `lookup(name)` raises `Hive::AgentProfiles::UnknownAgent` (which inherits from `Hive::ConfigError`) if missing. `registered_names` returns the live list — used by `Hive::Config.validate_agent_name!` so config errors list every valid profile.

`reset_for_tests!` clears the registry; per-test setup re-requires `hive/agent_profiles` to re-register the v1 built-ins.

## Built-in profiles

Auto-required from `lib/hive/agent_profiles.rb`:

For implementation identity, Claude translates normalized values to `--model
<model> --effort <effort>`, Codex to `--model <model> -c
model_reasoning_effort=<effort>`, and Grok to `--model <model>
--reasoning-effort <effort>`. Pi can resolve and optionally pin a concrete
provider-native model but declares effort unsupported. An unsupported effort
stays visible as requested in the durable profile identity value while native
argv omits it and `effective_effort` remains unset. A new explicit runtime
invocation request fails closed instead of silently omitting that requested
capability.

Active stage routing is stricter than that legacy identity path. Claude accepts
`default`, `inherit`, `low`, `medium`, `high`, `xhigh`, and `max`; Codex
accepts `default`, `inherit`, `none`, `minimal`, `low`, `medium`, `high`, and
`xhigh`; Grok accepts `default`, `inherit`, `none`, `minimal`, `low`, `medium`,
`high`, `xhigh`, and `max` through its native `--reasoning-effort` control,
while Pi rejects routed effort. Claude routing omits model
`inherit` and effort `default`/`inherit`. Codex routing emits model and
reasoning controls as global arguments before its subcommand. The typed
argument envelope retains profile, stage, values, and provenance and is
revalidated at the spawn boundary to prevent cross-profile argv reuse.

Durable routed implementation identities persist that typed envelope's
effective values and provenance as JSON-safe metadata, not rendered argv.
Reconstruction asks the stored profile to validate and render the metadata
again, which preserves global-versus-subcommand placement without consulting
live routing configuration. Historical identities without the metadata keep
their legacy flat identity argv path.

`Hive::ImplementationIdentity::EventBuilder` owns the durable journal envelope
shared by first-time identity capture and legacy reconstruction. It binds the
task, coding workflow/stage, durable attempt, input/ownership generations,
attempt-lease evidence, provenance, and payload in one place; `Store` retains
generation/selection policy and `Reconstructor` retains recovery policy.

- `claude` — default skip flag `--dangerously-skip-permissions`, `--add-dir`, `--max-budget-usd`, headless via `-p`, stream-json output with `--verbose`, Claude skill verifier, interim plus terminal usage extraction, and opt-in verified capabilities for `safe_mode` plus the minimal patrol review/fix contexts. Patrol disables slash commands; review exposes `Read,Grep,Glob,Write`, while fix additionally exposes `Bash,Edit`. The profile reserves 20,000 initial-context tokens for patrol admission. Message-start/delta counters support a true in-flight patrol stop. A structured terminal `result/error_max_budget_usd` event is surfaced as the per-run `budget_exhausted` outcome, distinct from account/rate/quota `limits_reached` recovery; ordinary prose is never used to infer it. Min version `2.1.118`. `:state_file_marker` mode. `AgentProfile#permission_flags(mode)` is the single source of truth for permission argv, shared by the headless `Hive::Agent` path and the tmux `Hive::ClaudeLauncher#wrapper_command` path: `bypassPermissions` (and a nil mode) yields `--dangerously-skip-permissions`, any other ordinary Claude mode yields `--permission-mode <mode>`.
- `codex` — `--dangerously-bypass-approvals-and-sandbox`, `--add-dir`, headless via the `exec` subcommand, `--json` output, and dedicated read-only/workspace-write sandbox bundles (approval policy `never`, ephemeral execution, and ignored user config/rules) for architecture discovery and fixes. Prompts are delivered on stdin with `-` in argv. No native budget flag. Hive consumes usage events when present, but real interim-event coverage remains unverified, so spawn/day quotas and the wall-clock timeout are the provider-independent fallback. Min version `0.125.0`. `:output_file_exists`.
- `pi` — no permission flag, no `--add-dir` (triggers `warn_isolation_reduced` when callers pass `add_dirs:` per ADR-018), preflight checks for `auth.json` beneath the same validated `PI_CODING_AGENT_DIR` (or default `~/.pi/agent`) used by skill discovery. Min version `0.70.2`. `:output_file_exists`.
- `grok` — headless via `-p <prompt>`, `--always-approve`, and
  `--output-format streaming-json`; normalized effort is pinned with
  `--reasoning-effort`. The profile alone declares
  `structured_output_protocol: :grok_end`, which scopes terminal
  `end.structuredOutput` authority and opacity to Grok while leaving custom
  profiles backward-compatible. Preflight accepts `XAI_API_KEY`,
  `GROK_CODE_XAI_API_KEY`, an explicit absolute credential file via
  `GROK_AUTH_PATH`, or `auth.json` under an absolute `GROK_HOME`/the default
  `~/.grok`; device login is `grok login --device-auth`. The direct path takes
  precedence over `GROK_HOME`, matching the CLI and allowing one
  refresh-token/lock domain to be mounted into isolated runners. Hive rejects
  relative path overrides, even when an API key is present, so its parent
  preflight and a child spawned in another working directory cannot consume
  different credential files or state directories. No add-dir or budget flag.
  Text events are concatenated into `final_message`; unavailable token usage
  stays nil. Min version `0.2.90`. `:output_file_exists`.
  `Hive::SkillCheck::Grok` resolves project/user skills plus enabled native
  installed-plugin skills under `GROK_HOME`; Compound Engineering is
  provisioned with Grok's own plugin install/enable/update commands. Native
  inspection runs from the target project and verifies the exact runtime skill
  source against the realpath-jailed installed plugin.

## Used by

- `Stages::Base.spawn_agent` — calls `AgentRuntime.prepare!` before spawning,
  then retains isolation/budget warnings and all workflow policy.
- `Hive::Agent` — obtains argv/stdin and normalized usage through
  `AgentRuntime`, while retaining process-group lifecycle and status policy.
- `Hive::DiagnosisAgent` and `Hive::DisplayName::Generator` — use the same
  compiler with their own output/lifecycle policies; diagnosis deliberately
  omits structured output-format flags.
- `Hive::Patrol::AgentLaunch` — obtains verified minimal patrol capability
  argv through `AgentRuntime.require_capability!`, while retaining the
  Claude-specific admission and turn-limit policy.
- `Hive::RefactorPatrol::ReviewAgentRunner` — uses Claude's read-only permission scope or a profile-declared native read-only sandbox, and pins the resolved refactor model/effort arguments.
- `Hive::RefactorPatrol::Fixer` — accepts only a profile with `workspace_write_supported?` and invokes it through the special `workspace-write` permission mode.
- `Stages::Base.record_usage` — reads each profile's `usage_extractor` output and stores per-spawn rows in `Hive::UsageDB`.
- `Hive::Config.validate_role_agent_names!` and `validate_reviewers!` — every `agent:` field in `review.{ci,triage,fix,browser_test}` and `review.reviewers[]` must resolve via `AgentProfiles.lookup`.
- `Hive::WorkflowPackage::RuntimePolicy` — legacy packages can still compile
  their command/domain policy, while current Honeycomb actors resolve their
  descriptor `permissions:` independently. Explicit `yolo` works on any
  profile. Bounded Claude mappings keep the native tool policy. Bounded Codex
  mappings use a generated named filesystem permission profile with no shell
  network, MCP servers, apps, plugins, memory, hooks, or subagents. Bounded Grok
  mappings run the static CLI inside bubblewrap with only declared task,
  package, and extra read roots mounted. For both portable runners, Hive asks
  for schema-constrained file content under a read-only policy and atomically
  writes only descriptor-authorized output paths after validating the complete
  response. Managed launches isolate the environment and inject only values
  authorized for the executing stable slot. The strict Claude MCP isolation
  file carries an explicit empty `mcpServers` object so current Claude Code
  releases accept the schema while exposing no servers.

## Managed skill inspection and provisioning

`Hive::AgentSkills::Inspector` always calls `AgentProfiles.lookup(name, cfg:
config)`, so project `agents.<name>.bin` overrides and profile minimum versions
match actual stage spawns. It then pairs each profile's native inventory with
`Hive::SkillCheck` resolution under `CLAUDE_CONFIG_DIR`, `CODEX_HOME`,
`PI_CODING_AGENT_DIR`, or `GROK_HOME`.

The profile is the runtime contract; `config/agent-skills.yml` is the package
contract. Adapters use the profile's binary/version gate plus manifest-declared
native actions, package source, and compatible version. Filtered target
resolution recursively retains package prerequisites; adapters fail closed
when a prerequisite is neither scheduled nor proven healthy. Codex package
operations snapshot the config after each successful prerequisite so a later
dependent operation accepts that exact expected transition instead of
misclassifying its own prerequisite's edit as external drift. Provisioning CLI
deadlines own and reap a process group so timed-out descendants cannot keep
installing in the background. Adapters do not alter the profile registry or
make arbitrary custom profiles provisionable. See
[[commands/doctor]] and [[commands/setup-agents]].

## Tests

- `test/unit/agent_runtime_test.rb` — immutable request/invocation/evidence
  contracts, exact four-provider prompt transport, fail-closed unsupported
  capabilities, bounded redacted failures, and observation/usage
  normalization.
- `test/unit/agent_profile_test.rb` — version/capability caches, env override, preflight, process-group timeout cleanup for version/help probes and stdout-inheriting descendants, workspace-write flags, and headless gate.
- `test/unit/agent_profile_modes_test.rb` — `:state_file_marker` / `:exit_code_only` / `:output_file_exists` branching in `Hive::Agent#handle_exit`.
- `test/unit/agent_profiles_test.rb` — registry register / lookup / unknown.
- `test/unit/spawn_agent_test.rb` — preflight ordering, isolation-warning trigger, default-profile fallback.
- `test/unit/workflow_package/runtime_policy_test.rb` — exact policy files,
  deny/command/domain enforcement, and multi-actor admission failure.
- `test/unit/pi_preflight_test.rb` — pi's auth.json preflight gate.
- `test/unit/grok_preflight_test.rb` — Grok environment/file auth and usage semantics.
- `test/unit/agent_skills/inspector_test.rb` — configured binary/home use and native/runtime evidence correspondence.

## Backlinks

- [[modules/agent]] · [[modules/config]]
- [[stages/review]] · [[architecture]] · [[commands/doctor]] · [[commands/setup-agents]]
- [[decisions]] (ADR-017 / ADR-018 / ADR-019)
