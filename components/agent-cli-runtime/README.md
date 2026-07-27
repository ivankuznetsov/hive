# Agent CLI Runtime

`agent-cli-runtime` is a small Ruby library for tools that integrate with
locally installed headless agent CLIs. It ships immutable profiles for Claude
Code, Codex CLI, Pi, and Grok CLI and compiles provider-neutral requests into
argv/stdin. It also reports typed capability evidence, extracts usage from
provider JSON events, and exposes an honest local diagnostic command.

## Install

```ruby
gem "agent-cli-runtime", "~> 0.1.0"
```

```ruby
require "agent_cli_runtime"
```

Ruby 3.4 or newer is required. Version 0.1.x is tested on Linux and macOS.

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
all-provider output as `claude`, `codex`, `pi`, `grok`.

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
`AgentCliRuntime::ObservableResult` with bounded, redacted diagnostics.

## Compatibility

Provider flags, event formats, and public value-object fields are
SemVer-governed behavior. Additive fields are compatible within 0.1.x; removing
or changing an existing field or meaning requires a new minor version while the
gem remains pre-1.0.

## Security

Diagnostics are bounded and redact common credential forms. The library never
prints credential file contents or environment values. Report vulnerabilities
privately through the
[package security policy](https://github.com/ivankuznetsov/agent-cli-runtime/security/policy).
