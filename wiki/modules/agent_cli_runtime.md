---
title: Agent CLI Runtime component
type: module
source: components/agent-cli-runtime, .github/workflows/agent-cli-runtime-release.yml
created: 2026-07-26
updated: 2026-07-26
tags: [agent, runtime, component, gem, cli]
---

**TLDR**: `agent-cli-runtime` is the first independently versioned gem kept in
the Hive monorepo. It exposes provider-neutral profiles, invocation
compilation, local prerequisite evidence, usage extraction, and normalized
results for Claude Code, Codex CLI, Pi, and Grok CLI. Hive remains the primary
consumer; the gem does not own orchestration or Hive policy.

## Public surface

The package lives at `components/agent-cli-runtime/`, loads with
`require "agent_cli_runtime"`, and exposes the `AgentCliRuntime` namespace.
Its built-in profiles are ordered `claude`, `codex`, `pi`, `grok`. Callers
construct immutable requests and receive immutable compiled invocations,
capability evidence, probe results, and observable results.

Compilation returns argv and optional stdin without executing a process.
Requested controls fail closed with `UnsupportedCapability` when a profile
cannot represent them. Provider profiles and extractors are public,
SemVer-governed behavior; orchestration policy stays injectable or outside the
package.

The `agent-runtime probe [PROVIDER|--all] [--json]` executable checks only
locally observable executable installation, version output, authentication
configuration presence, and declared capabilities. Its JSON envelope has
`schema_version: 1` and a `probes` array. Exit 0 means every requested local
prerequisite is ready, 1 means at least one is unavailable, and 64 means invalid
usage. `configured` never claims credential validity, provider health, or
account quota.

## Ownership boundary

The package does not spawn or supervise agents, select workflows, retry work,
interpret stages or markers, accept artifacts, decide success, own provider
budgets, or contain Hive defaults and skills. It can load and run without
`hive-cli` or Hive constants. Direct standard-library gem dependencies are
declared in its gemspec.

Until the post-publication cutover, `Hive::AgentRuntime` remains authoritative
inside Hive and focused parity tests compare the package against it. This
temporary duplication is bounded to the publish-first window; the held cutover
will preserve promised Hive constants as forwarding adapters and remove the
internal copy only after RubyGems verification and separate merge authority.

## Development and release

Package tests run directly from the subtree and through the root `rake test`
task. Candidate tooling builds one gem, records its source commit and dirty
state, checksums it, installs it into a private gem home, proves a clean require,
and exercises the executable.

Only `components/agent-cli-runtime/vX.Y.Z` tags can trigger the component
workflow. The tag, package version, exact main commit, and clean checkout must
agree. Candidate and platform-install jobs have no publication identity; the
`agent-cli-runtime-release` environment grants OIDC only to the publish job,
which pushes the previously verified bytes without rebuilding. Hive root tags
use a separate workflow and release surface. See `docs/RELEASING.md`.

## Compatibility

The initial public line is 0.1.x on Ruby 3.4 or newer, tested on Linux and
macOS. Additive fields are compatible within 0.1.x. Removing or changing an
existing public field, flag mapping, event meaning, or executable contract
requires a new minor release while pre-1.0. A published bad version is fixed
forward; yanking or ownership changes are separate operator decisions.

Related context: [[component-boundaries]], [[modules/agent_profile]], and
ADR-038 in [[decisions]].
