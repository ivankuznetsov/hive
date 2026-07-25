---
title: Component boundaries
type: reference
source: config/component-boundaries.yml, test/support/component_boundary_contract.rb
created: 2026-07-25
updated: 2026-07-25
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
| Attempts admission / future RunReceipt | `candidate` (guarded reference) | `require "hive/attempts/api"` → `Hive::Attempts::API` | [[modules/attempts]] |
| UserService | `candidate` | `require "hive/commands/service_installer/base"` → `Hive::Commands::ServiceInstaller::Base` | [[commands/daemon]] |
| Agent ABI | `candidate` | `require "hive/agent_profile"` → `Hive::AgentProfile` | [[modules/agent_profile]] |
| Agent Artifact Firewall | `candidate` | `require "hive/protected_files"` → `Hive::ProtectedFiles` | [[modules/protected_files]] |
| Skillpack | `candidate` | `require "hive/agent_skills"` → `Hive::AgentSkills` | [[commands/setup-agents]] |
| Safe Agent Git Gate | `candidate` | `require "hive/managed_git"` → `Hive::ManagedGit` | [[modules/git_ops]] |
| WorkLedger | `candidate` | `require "hive/task_journal"` → `Hive::TaskJournal` | [[state-model]] |

`candidate` means the current code is mapped, but callers, dependencies, or
policy still need refactoring before the seam is supported. `boundary-ready`
means the entry point, allowed dependency direction, consumer construction
rules, and clean-process load are enforced. It does not mean that a component
has earned a gem, version, repository, or release.

`Hive::Attempts::API` is the guarded reference admission slice. Its public
result contracts, focused clean-load proof, and exact internal construction
sites are enforced while it remains a `candidate`. Promotion is blocked because
Attempts reads WorkLedger projections while WorkLedger-owned
`lib/hive/task_projection/store.rb` still requires and constructs
`Hive::Attempts::Store`; U8 owns removal of that reciprocal source edge. The
reference slice does not publish raw storage, reconciliation, supervision,
capacity, loss-policy, cancellation, export, or generic lifecycle operations.

## Catalog contract

`config/component-boundaries.yml` is the canonical agent-readable inventory.
Each row names:

- the supported entry point and current public values/errors;
- owned source paths and explicit component dependencies;
- state, schema, lock, mutation-authority, and recovery responsibilities;
- known Hive consumers and internal collaborators;
- exact existing Hive files allowed to construct a named internal collaborator,
  with a non-blank architectural reason;
- the narrative wiki page and focused tests; and
- reviewed migration exceptions, if any.

Owned paths cannot overlap between components, component dependencies must form
an acyclic graph, and every path in the catalog must resolve inside the
repository. A temporary exception must include both a reason and the
implementation unit that removes it. A `boundary-ready` component cannot keep
an exception or depend on a `candidate` component.

## Enforcement

`test/support/component_boundary_contract.rb` is test-only architecture
tooling. U1 establishes this catalog and promotion guard; for every
`boundary-ready` row it:

1. parses literal Ruby `require` and `require_relative` calls and rejects upward
   dependencies on Hive commands, stages, web, release, or CLI code;
2. maps every component-owned Ruby file to its require path and rejects
   undeclared direct component dependencies;
3. for every row that declares forbidden constructions, scans production Ruby
   outside the component's owned paths and rejects literal `Constant.new`
   construction of listed internals except exact file/constant pairs recorded
   as current composition or compatibility sites; stale or newly listed-file
   authorizations fail validation; and
4. loads each ready entry point—and any explicitly requested candidate entry
   point—in a fresh Ruby process, verifies the documented
   constant, and rejects unrelated commands, stages, web code, or files owned
   by undeclared components.

Run the focused contract with:

```bash
bundle exec ruby -Itest -Ilib test/unit/component_boundaries_test.rb
```

The syntax scan is an architecture regression guard, not a Ruby sandbox. Its
construction rule covers literal `Constant.new`, not aliases or factory
methods. Construction authorization is file-granular: it rejects a named
internal from a newly listed file, but it does not distinguish multiple call
sites for that internal inside an already authorized composition root. It does
not claim to stop dynamic requires, reflection, monkeypatching, or arbitrary
same-user code. Those limits must not be weakened into security claims.

## Changing a boundary

Change one component per PR. Update its catalog row, focused consumer tests,
narrative wiki page, this page, and a `wiki/log.d/` fragment together. Promote
to `boundary-ready` only after clean loading, dependency direction, direct
consumer routing, focused tests, the broad Hive suite, and exact-head hosted CI
all pass. Packaging remains a separate, later decision gated by demonstrated
non-Hive demand and explicit release authority.
