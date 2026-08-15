# Agent CLI Runtime

`agent-cli-runtime` is a small Ruby library for tools that integrate with
locally installed headless agent CLIs. It ships immutable profiles for Claude
Code, Codex CLI, Pi, Grok CLI, and OpenCode and compiles provider-neutral
requests into argv/stdin. It also reports typed capability evidence, extracts
usage from provider JSON events, and exposes an honest local diagnostic
command. OpenCode adds an invocation-owned overlay and strict captured-result
normalizer while leaving process supervision with the caller.

## Install

```ruby
gem "agent-cli-runtime", "~> 0.2.0"
```

```ruby
require "agent_cli_runtime"
```

Ruby 3.4 or newer is required. The 0.2.x line is tested on Linux and macOS.

## Compile an invocation

```ruby
profile = AgentCliRuntime::Profiles.fetch(:codex)
request = AgentCliRuntime::Request.new(
  profile: profile,
  prompt: "Review the current diff",
  permission_mode: "read-only",
  model: "gpt-5.6-terra",
  effort: "high"
)

invocation = AgentCliRuntime.compile(request)
invocation.argv       # frozen argv; no shell interpolation
invocation.stdin_data # prompt text for stdin-style providers
```

Compilation does not execute the returned command. Unsupported requested
controls raise `AgentCliRuntime::UnsupportedCapability` with typed evidence
instead of silently widening the request.

`permission_mode: nil` selects the profile's default non-interactive permission
flags, which may include a provider's bypass flag. Pass `"read-only"` or
`"workspace-write"` explicitly when the integration requires that constraint.
A profile raises instead of pretending to enforce a mode its CLI cannot
represent.

## Public API

- `compile(request)` returns a frozen argv/stdin invocation.
- `probe(profile)` and `probe_all` report local prerequisite evidence without
  contacting a provider.
- `prepare!(profile)` requires that local probe to be ready.
- `require_capability!(profile, name)` verifies a named CLI capability and
  returns typed evidence.
- `extract_usage(profile, event)` normalizes provider usage when present and
  returns `nil` when usage is absent or malformed.
- `observe(profile, result)` normalizes bounded, redacted result metadata.
- `prepare!(open_code_preparation)` creates and probes an isolated OpenCode
  overlay and returns a `PreparedInvocation`; it does not spawn OpenCode.
- `parse_run(profile, stdout:)` parses a successful OpenCode JSONL capture
  into the session and terminal-message identity required for inspection.
- `prepare_inspection(prepared, parsed_run)` compiles the non-model sanitized
  session-export command without executing it.
- `normalize(profile, captured, requested_route:)` returns one typed OpenCode
  outcome from caller-captured run, termination, and inspection evidence.

Provider arguments accept a built-in name or an `AgentCliRuntime::Profile`.
Unknown built-in names raise `AgentCliRuntime::UnknownProvider`; they are not
converted into generic probe or capability failures.

## Custom profiles

```ruby
profile = AgentCliRuntime::Profile.new(
  name: :acme,
  bin_default: "acme-agent",
  env_bin_override_keys: ["ACME_AGENT_BIN"],
  headless_flag: "run",
  version_flag: "--version",
  min_version: "1.2.0",
  prompt_style: :stdin,
  read_only_flags: ["--sandbox", "read-only"],
  credential_environment_keys: ["ACME_API_KEY", "ACME_OAUTH_TOKEN"],
  configuration_environment_key: "ACME_HOME",
  default_configuration_directory: ".acme",
  cli_capabilities: {
    safe_mode: ["--safe-mode"]
  },
  usage_extractor: ->(event) { event["usage"] },
  auth_configuration_probe: ->(home:, env:) {
    AgentCliRuntime::AuthConfiguration.new(
      status: env["ACME_API_KEY"].to_s.empty? ? :missing : :configured,
      source: "environment"
    )
  }
)

request = AgentCliRuntime::Request.new(
  profile: profile,
  prompt: "Inspect the project",
  permission_mode: "read-only",
  capabilities: [:safe_mode]
)
AgentCliRuntime.compile(request)
```

Custom capability names cannot shadow the standard capability vocabulary.
Capability checks use discrete argv, inspect the installed CLI's help, and
fail closed when a declared option is not advertised.
`credential_environment_keys` is an immutable compatibility inventory for
orchestrators that isolate a named CLI session; it contains variable names,
never their values.
`configuration_environment_key` and `default_configuration_directory` describe
where the CLI owns its subscription/session state. `configuration_directory`
resolves that location from a caller-supplied home and environment without
reading credentials or deciding authentication policy.

## Prepare and normalize OpenCode

OpenCode `1.18.16+` requires an exact `provider/model` route and an explicit,
read-only configuration source. Configuration may define providers and an
exact default model, but it must not contain credential values. Name the
credential environment variables the caller is allowed to forward instead.

```ruby
require "agent_cli_runtime"
require "tmpdir"

route = "anthropic/claude-sonnet-4-5"
profile = AgentCliRuntime::Profiles.fetch(:opencode)
request = AgentCliRuntime::Request.new(
  profile: profile,
  prompt: "Make the requested atomic edit",
  permission_mode: "workspace-write",
  model: route,
  effort: "high"
)
preparation = AgentCliRuntime::OpenCodePreparationRequest.new(
  request: request,
  working_directory: Dir.pwd,
  invocation_root: File.join(Dir.tmpdir, "my-opencode-invocation"),
  configuration: {
    "model" => route,
    "provider" => {
      "anthropic" => { "npm" => "@ai-sdk/anthropic" }
    }
  },
  credential_environment_keys: ["ANTHROPIC_API_KEY"],
  additional_read_roots: [Dir.pwd],
  additional_write_roots: [Dir.pwd]
)

prepared = AgentCliRuntime.prepare!(preparation)
begin
  # The caller owns spawning, capture, timeout/cancellation, and process-tree
  # cleanup. Forward only this selected environment to the child.
  run_argv = prepared.invocation.argv
  run_stdin = prepared.invocation.stdin_data
  run_environment = prepared.environment_for(env: ENV)

  # After a zero main-process exit, parse the captured JSONL and run the
  # separately compiled, non-model sanitized export under the same overlay.
  parsed = AgentCliRuntime.parse_run(:opencode, stdout: run_stdout)
  inspection = AgentCliRuntime.prepare_inspection(prepared, parsed)
  inspection_argv = inspection.argv
  inspection_environment = inspection.environment_for(env: ENV)

  captured = AgentCliRuntime::CapturedResult.new(
    stdout: run_stdout,
    stderr: run_stderr,
    termination: AgentCliRuntime::TerminationEvidence.new(exit_code: 0),
    inspection_output: sanitized_export_stdout
  )
  outcome = AgentCliRuntime.normalize(
    :opencode, captured, requested_route: prepared.requested_route
  )
ensure
  prepared.cleanup! if prepared
end
```

`run_stdout`, `run_stderr`, and `sanitized_export_stdout` above are captures
provided by the caller's process supervisor. Execute the inspection only after
a successful main run. For a timeout, cancellation, signal, or non-zero exit,
construct the matching `TerminationEvidence` and normalize without pretending
that incomplete output is a successful result.

Preparation creates owner-private config, data, cache, and state paths below
the fresh invocation root; redirects OpenCode into them; disables ambient
project/default discovery and remote model refresh; checks version, required
flags, selected auth, cached route, and requested variant locally; and returns
discrete argv/environment values. It never sends a prompt or model request.
`PreparedInvocation#cleanup!` removes only invocation-owned paths and is safe
to call twice. Call it from the process owner's `ensure` path after every
pre-spawn and post-spawn outcome.

`read-only` denies edits, shell, unsafe tools, and external writes.
`workspace-write` permits edits only under the declared write roots and still
denies unrestricted shell. A `nil` permission mode is rejected unless the
consumer supplies an explicit typed `OpenCodePermissionPolicy`; the ordinary
preparation API never silently falls back to a bypass. Plugin sources are
explicit, and `--pure` remains enabled when no plugin was selected.

A completed outcome contains one bounded final assistant message, requested
and sanitized-export-observed routes, and nullable input/output/cache
read/cache write/reasoning/cost fields. Missing evidence stays `nil`; numeric
zero stays zero. Other outcome kinds are `authentication_failure`,
`configuration_failure`, `cli_failure`, `malformed_output`, `cancelled`, and
`timed_out`. Diagnostics and unknown-event summaries are bounded and redacted.

Maintainers can run the installed-CLI offline contract without a prompt or
model request:

```sh
bundle exec ruby -Itest test/opencode_offline_smoke_test.rb
```

If an installation command is itself a package-manager shim, set
`AGENT_CLI_RUNTIME_OPENCODE_OFFLINE_BIN` to the already-installed native
OpenCode executable so the smoke cannot trigger shim installation or refresh
behavior.

The authenticated atomic-edit smoke is separately gated and refuses to run
without an explicit route, config path, credential variable name, opt-in, and
non-empty selected credential:

```sh
AGENT_CLI_RUNTIME_OPENCODE_LIVE=1 \
AGENT_CLI_RUNTIME_OPENCODE_LIVE_ROUTE=anthropic/claude-sonnet-4-5 \
AGENT_CLI_RUNTIME_OPENCODE_LIVE_CONFIG=/absolute/path/opencode.json \
AGENT_CLI_RUNTIME_OPENCODE_LIVE_CREDENTIAL_ENV=ANTHROPIC_API_KEY \
ANTHROPIC_API_KEY=... \
bundle exec ruby -Itest test/opencode_live_test.rb
```

The live test records only route, CLI version, outcome/usage availability, and
cleanup state. It does not print the credential or raw selected config. A
missing opt-in input is an explicit skip, not a deterministic-suite failure.

## Inspect local prerequisites

```ruby
probe = AgentCliRuntime.probe(:codex)
probe.ready
probe.version
probe.auth_configuration.status

# Returns the ready probe or raises AgentCliRuntime::ProbeError.
AgentCliRuntime.prepare!(:codex)
```

```sh
agent-runtime probe codex
agent-runtime probe --all --json
```

The JSON contract is `{"schema_version":1,"probes":[...]}` and always orders
all-provider output as `claude`, `codex`, `pi`, `grok`, `opencode`.

- Exit `0`: every requested local probe is ready.
- Exit `1`: at least one requested local prerequisite is unavailable.
- Exit `64`: invalid usage.

The probe observes only the local executable, version output, authentication
configuration presence, and declared capabilities. `configured` means a
recognized local file or environment variable is present. It does not mean the
credential is valid, the provider is online, or the account has quota.

## Normalize provider output

```ruby
usage = AgentCliRuntime.extract_usage(
  :codex,
  "type" => "turn.completed",
  "usage" => {
    "input_tokens" => 120,
    "output_tokens" => 42
  }
)
# => { input: 120, output: 42, cached: 0, model: nil }

result = AgentCliRuntime.observe(
  :codex,
  exit_code: 0,
  timed_out: false,
  status: :completed,
  usage: usage,
  final_message: "Review complete"
)
result.status # => :completed
result.usage  # => the normalized usage hash
```

Malformed or unrelated events return `nil` from `extract_usage`; they do not
invent zero-token usage. `observe` returns a frozen
`AgentCliRuntime::ObservableResult` with bounded, redacted diagnostics. A
trusted caller may also supply an already-normalized `provider_signal`; the
runtime carries that optional immutable value but does not classify failures or
own provider-health policy.

## Compatibility

Provider flags, event formats, and public value-object fields are
SemVer-governed behavior. Additive fields are compatible within 0.2.x; removing
or changing an existing field or meaning requires a new minor version while the
gem remains pre-1.0.

## Security

Diagnostics are bounded and redact common credential forms. The library never
prints credential file contents or environment values. Report vulnerabilities
privately through the
[package security policy](https://github.com/ivankuznetsov/agent-cli-runtime/security/policy).
