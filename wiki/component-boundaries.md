---
title: Component boundaries
type: reference
source: config/component-boundaries.yml, test/support/component_boundary_contract.rb
created: 2026-07-25
updated: 2026-07-26
tags: [architecture, components, boundaries, monorepo]
---

**TLDR**: Hive keeps reusable mechanisms in this monorepo and makes their
supported Ruby seams explicit before considering gems. The machine-readable
catalog records ownership, entry points, contracts, dependencies, consumers,
state and recovery responsibilities, maturity, and focused tests. Hive remains
the first and primary consumer.

## Current catalog

| Component | State | Current entry point | Narrative context |
|-----------|-------|---------------------|-------------------|
| Attempts admission / future RunReceipt | `candidate` | `require "hive/attempts/api"` → `Hive::Attempts::API` | [[modules/attempts]] |
| UserService | `candidate` | `require "hive/commands/service_installer/base"` → `Hive::Commands::ServiceInstaller::Base` | [[commands/daemon]] |
| Agent ABI | `boundary-ready`; standalone package candidate | `require "hive/agent_runtime"` → `Hive::AgentRuntime` | [[modules/agent_cli_runtime]], [[modules/agent_profile]] |
| Agent Artifact Firewall | `candidate` | `require "hive/protected_files"` → `Hive::ProtectedFiles` | [[modules/protected_files]] |
| Skillpack | `candidate` | `require "hive/agent_skills"` → `Hive::AgentSkills` | [[commands/setup-agents]] |
| Safe Agent Git Gate | `candidate` | `require "hive/managed_git"` → `Hive::ManagedGit` | [[modules/git_ops]] |
| WorkLedger | `candidate` | `require "hive/task_journal"` → `Hive::TaskJournal` | [[state-model]] |

`candidate` means the current code is mapped, but callers, dependencies, or
policy still need refactoring before the seam is supported. `boundary-ready`
means the entry point, allowed dependency direction, consumer construction
rules, and clean-process load are enforced. It does not mean that a component
has earned a gem, version, repository, or release.

`Hive::Attempts::API` is an existing admission slice, but U1 records Attempts
as a `candidate`: daemon lifecycle code still constructs its store and
reconciler internals directly. U2 owns reconciling that construction and may
promote Attempts only after the completed boundary proof passes.

The `Agent ABI` is boundary-ready below orchestration. `AgentRuntime` exposes
immutable request, compiled invocation, capability/probe evidence, and
observable-result values while preserving `AgentProfile.new(...)` and
`AgentProfiles.register` as extension points. Claude, Codex, Pi, Grok, and
custom profiles remain adapters inside the boundary. Hive owns process
lifetime, timeouts, retries, workflow selection, artifact acceptance, and
stage success. `Hive::SecretPatterns` remains shared Hive infrastructure rather
than component-owned state: both the ABI's bounded diagnostics and the future
artifact firewall consume it.

The package-only extraction lives at `components/agent-cli-runtime/` and
publishes the neutral `AgentCliRuntime` namespace plus the bounded
`agent-runtime` diagnostic executable. Until the separately held Hive cutover,
`Hive::AgentRuntime` remains Hive's authoritative implementation and package
parity tests prevent the temporary publication-window copy from drifting.
Landing the package does not change Hive's gem dependency graph. See
[[modules/agent_cli_runtime]] for the public surface and release boundary.

Its public standalone repository is deliberately a one-way distribution
projection. Scheduled main snapshots and manually requested release snapshots
record the exact Hive component commit. The canonical checkout owns projection
logic and the release workflow independently reconstructs the expected tag tree
before publication; immutable mirror tag rules protect that verified result.
Development, issues, pull requests, version selection, and RubyGems publication
remain owned by this monorepo. The mirror improves focused discovery without
creating a second source of truth.

## Catalog contract

`config/component-boundaries.yml` is the canonical agent-readable inventory.
Each row names:

- the supported entry point and current public values/errors;
- owned source paths and explicit component dependencies;
- state, schema, lock, mutation-authority, and recovery responsibilities;
- known Hive consumers and internal collaborators;
- the narrative wiki page and focused tests; and
- reviewed migration exceptions, if any.

Owned paths cannot overlap between components, component dependencies must form
an acyclic graph, and every path in the catalog must resolve inside the
repository. A temporary exception must include both a reason and the
implementation unit that removes it. A `boundary-ready` component cannot keep
an exception.

## Enforcement

`test/support/component_boundary_contract.rb` is test-only architecture
tooling. U1 establishes this catalog and promotion guard; for every
`boundary-ready` row it:

1. parses literal Ruby `require` and `require_relative` calls and rejects upward
   dependencies on Hive commands, stages, web, release, or CLI code;
2. maps every component-owned Ruby file to its require path and rejects
   undeclared direct component dependencies;
3. scans production Ruby outside the component's owned paths and rejects
   literal `Constant.new` construction of listed internals; and
4. loads the entry point in a fresh Ruby process, verifies the documented
   constant, and rejects unrelated commands, stages, web code, or files owned
   by undeclared components.

Run the focused contract with:

```bash
bundle exec ruby -Itest -Ilib test/unit/component_boundaries_test.rb
```

The syntax scan is an architecture regression guard, not a Ruby sandbox. Its
construction rule covers literal `Constant.new`, not aliases or factory
methods. It does not claim to stop dynamic requires, reflection, monkeypatching,
or arbitrary same-user code. Those limits must not be weakened into security
claims.

## Changing a boundary

Change one component per PR. Update its catalog row, focused consumer tests,
narrative wiki page, this page, and a `wiki/log.d/` fragment together. Promote
to `boundary-ready` only after clean loading, dependency direction, direct
consumer routing, focused tests, the broad Hive suite, and exact-head hosted CI
all pass. Packaging remains a separate decision gated by demonstrated non-Hive
demand and explicit release authority. Agent CLI Runtime has passed that gate
with HiveBench as the named adopter; no other catalog row inherits that
decision.
