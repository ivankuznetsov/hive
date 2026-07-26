# Agent CLI Runtime

`agent-cli-runtime` is a small Ruby library for tools that need to describe
and inspect locally installed headless agent CLIs without owning an agent
orchestration system.

It ships immutable profiles for Claude Code, Codex CLI, Pi, and Grok CLI;
compiles provider-neutral requests into argv/stdin; reports typed capability
evidence; extracts usage from provider JSON events; and exposes an honest local
diagnostic command.

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

## Inspect local prerequisites

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

## Scope and compatibility

The library does not spawn or supervise agents, retry work, run workflows,
accept artifacts, or interpret Hive state. Provider flags and event formats are
SemVer-governed public behavior. Additive fields are compatible within 0.1.x;
removing or changing an existing field or meaning requires a new minor version
while the gem remains pre-1.0.

Development remains in the Hive monorepo under
`components/agent-cli-runtime`. Hive is the primary consumer and HiveBench is
the first named external adopter. The Hive maintainer team owns compatibility,
security response, and releases for the package.

## Development

```sh
cd components/agent-cli-runtime
bundle exec rake test
gem build agent-cli-runtime.gemspec
```

Release instructions live in the repository’s `docs/RELEASING.md`. Releases
use component-scoped tags and publish exact preverified gem bytes through
RubyGems trusted publishing.

## Security

Diagnostics are bounded and redact common credential forms. The library never
prints credential file contents or environment values. Report vulnerabilities
through the Hive repository’s security policy.
