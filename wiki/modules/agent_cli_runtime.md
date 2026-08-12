---
title: Agent CLI Runtime component
type: module
source: components/agent-cli-runtime, components/agent-cli-runtime/mirror, .github/workflows/agent-cli-runtime-release.yml
created: 2026-07-26
updated: 2026-08-12
tags: [agent, runtime, component, gem, cli]
---

**TLDR**: `agent-cli-runtime` is the first independently versioned gem kept in
the Hive monorepo. It exposes provider-neutral profiles, invocation
compilation, local prerequisite evidence, usage extraction, and normalized
results for Claude Code, Codex CLI, Pi, Grok CLI, and OpenCode. Hive remains
the primary consumer; the gem does not own orchestration or Hive policy.

## Public surface

The package lives at `components/agent-cli-runtime/`, loads with
`require "agent_cli_runtime"`, and exposes the `AgentCliRuntime` namespace.
Its built-in profiles are ordered `claude`, `codex`, `pi`, `grok`, `opencode`.
The appended profile leaves the order and behavior of the four legacy profiles
unchanged. Callers construct immutable requests and receive immutable compiled
invocations, capability evidence, probe results, and observable results.
Each profile also exposes an immutable `credential_environment_keys`
inventory. This is compatibility metadata for an orchestrator that needs to
remove ambient credentials when selecting a named subscription/session; it
contains names only and does not move credential values into the package.
The companion `configuration_environment_key`,
`default_configuration_directory`, and `configuration_directory` contract
describes the CLI-owned subscription/session directory. The extracted package
owns these provider-specific names; it does not provision API keys or choose an
authentication mode.
Hive uses that inventory to remove ambient API credentials from child launches
and select CLI subscription/session state. That is Hive policy, not a package
restriction for independent consumers.

Compilation returns argv and optional stdin without executing a process.
Requested controls fail closed with `UnsupportedCapability` when a profile
cannot represent them. Provider profiles and extractors are public,
SemVer-governed behavior; orchestration policy stays injectable or outside the
package.

OpenCode adds a stricter, additive preparation surface because its safe
headless contract depends on an invocation-owned configuration overlay. An
`OpenCodePreparationRequest` identifies an exact `provider/model`, a selected
configuration source, named credential environment keys, a working directory,
declared extra roots, and a fresh absolute invocation root. `prepare!` performs
only bounded local version/help/auth/model-inventory inspections, writes
owner-private XDG config/data/cache/state homes, compiles deny-first permission
rules, and returns a `PreparedInvocation`. The value exposes discrete argv,
non-secret child-environment overrides, requested-route evidence, generated
paths, and idempotent `cleanup!`; it never starts `opencode run`. The process
owner forwards only the named credential keys and must invoke cleanup from its
own lifecycle `ensure`.

The OpenCode route-aware probe requires `1.18.16+`, all pinned run/export
flags, a selected authentication source, and the exact cached
`provider/model` plus requested variant while remote model fetching and ambient
project configuration are disabled. Generic `probe(profile)` and
`prepare!(profile)` remain compatible for legacy profiles. OpenCode's ordinary
`nil`, `read-only`, and `workspace-write` compilation paths fail closed unless
the prepared overlay supplies its explicit typed policy and trusted `--auto`
argument.

The public facade includes `compile`, `prepare!`, `require_capability!`,
`extract_usage`, `observe`, `probe`, and `probe_all`. It accepts built-in names
or custom `Profile` objects, preserves `UnknownProvider` as a typed caller
error, exposes custom CLI capabilities in static probe evidence, and rejects
custom names that collide with the standard capability vocabulary. Missing
usage stays `nil`; terminal events without counters do not become measured
zero-token events. Observable results also carry an optional immutable
`provider_signal` supplied by a trusted caller. The component does not classify
that signal or own provider-health policy.

For compatibility with Hive's trusted legacy headless launches,
`permission_mode: nil` still selects a legacy provider's bypass flag. OpenCode
requires a prepared explicit policy. Independent
consumers should pass `read-only` or `workspace-write` when they require those
restrictions; unsupported enforcement fails closed. Version probes execute
with their supplied environment, reject output containing multiple distinct
version tokens, and terminate the full process group with a TERM/KILL and
bounded-reader cleanup path on timeout. Grok environment authentication ignores
unused file-path overrides, while file-backed authentication still validates
absolute paths.

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

Hive consumes `agent-cli-runtime ~> 0.1.1` directly. Source development resolves
the monorepo component path; installed Hive and the packaged Web lock resolve
the same compatible release from RubyGems. `Hive::AgentRuntime` preserves its
public request, probe, error, and result names as a forwarding facade, while
`Hive::AgentProfile` wraps package profiles with only Hive-owned skill, model
routing, default-model, status, and policy metadata. The four built-in Hive
profiles reference the package's profile objects instead of copying provider
flags, probes, usage extractors, or configuration metadata.

The published 0.1.1 candidate was built from canonical commit
`590fe343f585705651f277ddf198fcf4aa65f135`, published by the protected
component workflow, and independently fetched from RubyGems with SHA-256
`f1b833320397e63268ebc9c739f790b42e2f767d6d0e69bed728f220913da5a2`.
Fresh isolated installation, require, executable-version, and JSON probe
checks matched the retained workflow artifact before Hive's cutover.

## Development and release

Package tests run directly from the subtree and through the root `rake test`
task. Candidate tooling builds one gem, records its source commit and dirty
state, checksums it, installs it into a private gem home, proves a clean require,
and exercises the executable. Root parity fixtures cover non-default
compilation, local probes, named capability evidence, provider usage variants,
and observable normalization/redaction across all four built-ins.

Only `components/agent-cli-runtime/vX.Y.Z` tags can trigger the component
workflow. The tag, package version, exact main commit, and clean checkout must
agree. Candidate and platform-install jobs have no publication identity; the
`agent-cli-runtime-release` environment grants OIDC only to the publish job,
which pushes the previously verified bytes without rebuilding. Hive root tags
use a separate workflow and release surface. Every component release job has a
15-minute execution timeout and the exact candidate is retained for 30 days to
survive reviewer delay. Repository operators must separately enforce a
component-tag ruleset, required reviewers on the release environment, and an
environment deployment policy restricted to matching component tags. See
`docs/RELEASING.md`.

The public
[`ivankuznetsov/agent-cli-runtime`](https://github.com/ivankuznetsov/agent-cli-runtime)
repository is a read-only distribution projection, not a second development
home. Its scheduled or manually dispatched sync copies this component to the
mirror root and writes `.mirror-source.json` with the exact canonical component
commit. The mirror invokes the projector from the canonical checkout and
requires the complete canonical admin set before mutation. Mirror Git writes
use a repository-scoped deploy key because GitHub's generated token cannot
update workflow files; API reads and release creation retain the shorter-lived
generated token. A separate manual mirror workflow projects an already
approved, fully qualified component tag to an orphan `vX.Y.Z` source-snapshot
tag. It reuses the component release preflight, verifies the exact version is
already on RubyGems, compares the projected tree with an independently archived
canonical tree, requires a live immutable `refs/tags/v*` ruleset, verifies the
local tag as an installable gem, and only then pushes it and creates the focused
GitHub release. Neither mirror workflow can modify Hive, publish RubyGems
bytes, or choose a version; issues, pull requests, and release authority stay
here.

## Compatibility

The public line is 0.1.x on Ruby 3.4 or newer, tested on Linux and
macOS. Additive fields are compatible within 0.1.x. Removing or changing an
existing public field, flag mapping, event meaning, or executable contract
requires a new minor release while pre-1.0. A published bad version is fixed
forward; yanking or ownership changes are separate operator decisions.

Related context: [[component-boundaries]], [[modules/agent_profile]], and
ADR-038 in [[decisions]].
