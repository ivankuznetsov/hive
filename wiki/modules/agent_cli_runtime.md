---
title: Agent CLI Runtime component
type: module
source: components/agent-cli-runtime, components/agent-cli-runtime/mirror, .github/workflows/agent-cli-runtime-release.yml
created: 2026-07-26
updated: 2026-08-22
tags: [agent, runtime, component, gem, cli]
---

**TLDR**: `agent-cli-runtime` gives Ruby applications one stable integration
layer for Claude Code, Codex CLI, Pi, Grok CLI, and OpenCode. Its versioned
profiles centralize provider-specific commands, local capability checks,
environment rules, usage extraction, and result normalization so consumers
can add, switch, and upgrade agent CLIs behind one request and result
vocabulary. It is the first independently versioned gem kept in the Hive
monorepo, with Hive as its primary consumer and orchestration policy owner.

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

`bin/hive` prefers `components/agent-cli-runtime/lib` when it is present in a
source checkout. This keeps dogfood and benchmark clones on the component
contract reviewed in the same commit, even when the operator also has an older
published `agent-cli-runtime` gem installed. Packaged Hive remains unchanged
because its gem does not include the monorepo component directory.

Compilation returns argv and optional stdin without executing a process.
Requested controls fail closed with `UnsupportedCapability` when a profile
cannot represent them. Provider profiles and extractors are public,
SemVer-governed behavior; orchestration policy stays injectable or outside the
package.

The prompt transport distinguishes stdin with an argv marker (`:stdin`, used
by Codex) from a raw non-TTY pipe (`:piped_stdin`, used by Pi and OpenCode).
Both CLIs construct the initial message from that pipe, so implementation-sized
prompts never occupy one operating-system-limited argv element. This matters
before the total `ARG_MAX` ceiling: Linux rejects one argument at roughly 128
KiB, which a deeply reviewed plan can exceed on its own.

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
owner forwards only the named credential keys, binds any compiled `stdin_data`
to the run process, and must invoke cleanup from its own lifecycle `ensure`.

The OpenCode route-aware probe requires `1.18.16+`, all pinned run/export
flags, a selected authentication source, and an exact `provider/model` plus
requested variant while remote model fetching and ambient project
configuration are disabled. An exact route declared by the selected overlay is
authoritative and skips the large verbose CLI inventory; an undeclared route
must still exist in that bounded local inventory. Generic `probe(profile)` and
`prepare!(profile)` remain compatible for legacy profiles. OpenCode's ordinary
`nil`, `read-only`, and `workspace-write` compilation paths fail closed unless
the prepared overlay supplies its explicit typed policy and trusted `--auto`
argument.

Prepared overlays reserve every XDG/config/disable key, remove selected
per-agent permission blocks, forward credentials only when they match the
requested provider, and emit worktree-relative edit patterns. Nested read-only
exceptions are re-applied after writable rules because OpenCode uses the last
matching permission. Workspace-write requests may also carry explicit
deny-first Bash patterns; absent patterns keep shell denied, and the patterns
remain application permissions rather than an OS sandbox. Probe children start from an explicitly cleared
environment, and cleanup refuses a replaced invocation root without masking a
completed Hive result.

OpenCode also uses the profile's additive strict result-parser hook. A caller
passes captured stdout/stderr plus typed exit, signal, timeout, or cancellation
evidence. A successful run must contain one consistent session, a recognized
terminal `step_finish`, and text for that terminal message identity. The caller
then executes the separately compiled non-model `export SESSION --sanitize`
inspection under the same overlay. Normalization correlates the exported
assistant record, records requested and actual nested routes separately, and
uses its token/cache/reasoning/cost fields without converting absence to zero.
Timeout, cancellation, authentication failure, configuration failure, generic
CLI failure, malformed output, and completion remain distinct outcomes.
Nonzero OpenCode runs that carry an upstream idle-timeout/504 diagnostic are
normalized as `timed_out` rather than generic `cli_failure`; Hive projects that
use marker-owned stages record the ordinary transient `timeout` reason while
preserving any partial artifact bytes for scheduler-owned retry.
When OpenCode exits zero with an empty terminal assistant message after writing
a current terminal stage artifact, Hive trusts that controller-scoped artifact;
the strict malformed transcript remains a failure whenever the artifact itself
is incomplete.
Unknown additive event payloads are discarded after binding any supplied
session identity; only bounded, redacted type summaries survive. Exact
truncation evidence is carried separately from final-message bytes. Legacy
profile extraction and observation are unchanged.

The public facade includes `compile`, `prepare!`, `require_capability!`,
`extract_usage`, `extract_provider_error`, `observe`, `probe`, and `probe_all`.
It accepts built-in names or custom `Profile` objects, preserves
`UnknownProvider` as a typed caller error, exposes custom CLI capabilities in
static probe evidence, and rejects custom names that collide with the standard
capability vocabulary. Missing usage stays `nil`; terminal events without
counters do not become measured zero-token events. Pi's zero-exit
`stopReason: "error"` refusals and `stopReason: "length"` incomplete turns are
normalized separately: the latter carries `kind: model_output_limit`, so Hive
reports model-output exhaustion instead of blaming a missing artifact.
Observable results also carry an optional immutable `provider_signal` supplied
by a trusted caller. The component does not classify that signal or own
provider-health policy.

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

Hive requires `agent-cli-runtime ~> 0.2.0` and resolves the monorepo component
path during development. This keeps installed Hive on the independently
published OpenCode-capable line while allowing compatible 0.2.x patches;
component publication and Hive dependency cutover remain separate operations.
OpenCode's prepared invocation keeps its configuration, data, cache, state,
and temporary roots private, while Hive forwards the operator-selected
`GEM_HOME` and `GEM_PATH` alongside the existing base process environment. A
systemd daemon commonly has no explicit `GEM_PATH`; in that case Hive supplies
the effective `Gem.path` of its own Ruby process. Those paths are runtime
inputs, like `PATH`: dropping them can make a
repository's checked-in Ruby binstubs fail to load `bundler/setup` even though
the exact same binstubs work for the operator. Ruby code-injection options such
as `RUBYOPT` remain outside the forwarded environment.
`Hive::AgentRuntime`
preserves its
public request, probe, error, and result names as a forwarding facade, while
`Hive::AgentProfile` wraps package profiles with only Hive-owned skill, model
routing, default-model, status, and policy metadata. The five source-built Hive
profiles reference the package's profile objects instead of copying provider
flags, probes, usage extractors, or configuration metadata.

Source Web declares the component as an explicit path gem so Rails boots
against the same reviewed ABI. Managed Web provisioning and server launches
replace that relative source with the installed component gem root through
`HIVE_AGENT_CLI_RUNTIME_ROOT`, parallel to the existing `HIVE_CLI_ROOT` seam.

The published 0.2.0 candidate was built from canonical commit
`c8f62cacefb9d5982ab0e8d2328071763b3736c4`, published by the protected
component workflow, and independently fetched from RubyGems with SHA-256
`b813b54d0dded7ecab2a7aa569d997c7d4c24666b76ba675196cb30e10e08320`.
Fresh isolated installation, require, executable-version, and ready OpenCode
JSON probe checks matched the retained workflow artifact before Hive's cutover.

## Development and release

Package tests run directly from the subtree and through the root `rake test`
task. Candidate tooling builds one gem, records its source commit and dirty
state, checksums it, installs it into a private gem home, proves a clean require,
and exercises the executable. Root parity fixtures cover non-default
compilation, local probes, named capability evidence, provider usage variants,
and observable normalization/redaction across all five built-ins. The
0.2.0 release promotes OpenCode to the public compatibility surface without
changing the component's caller-owned process-supervision boundary or
authorizing a Hive release.
`bin/release-preflight` remains
tag-bound and is not run against a fabricated tag during candidate work.

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
local tag as an installable gem, and builds the focused GitHub release notes
from that verified tag's `CHANGELOG.md`. A checked extractor rejects missing or
whitespace-only version sections before the immutable tag is pushed, and the
release step consumes that already validated file. This ordering also makes a
retry with an existing matching tag independent of mutable mirror `main`.
Neither mirror workflow can modify Hive, publish RubyGems
bytes, or choose a version; issues, pull requests, and release authority stay
here.

## Compatibility

The 0.2.x line runs on Ruby 3.4 or newer and is tested on Linux and macOS.
Version 0.2.0 accounts for the additive OpenCode prepared-invocation,
route-probe, strict-parser, identity, and usage contracts. Removing or changing
an existing public field, flag mapping, event meaning, or executable contract
requires a minor release while pre-1.0. A published bad version is fixed
forward; yanking or ownership changes are separate operator decisions.

Related context: [[component-boundaries]], [[modules/agent_profile]], and
ADR-038 in [[decisions]].
