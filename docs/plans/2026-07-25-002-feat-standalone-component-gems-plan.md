---
title: Agent CLI Runtime Gem - Plan
type: feat
date: 2026-07-25
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
deepened: 2026-07-25
---

# Agent CLI Runtime Gem - Plan

## Goal Capsule

- **Objective:** Publish the provider-neutral compile/probe/decode boundary as `agent-cli-runtime` 0.1.0 with the `AgentCliRuntime` namespace, `require "agent_cli_runtime"` entry point, and `agent-runtime` diagnostic executable while retaining one canonical monorepo.
- **Authority:** The user explicitly approved the public name, namespace, require path, version, executable, component package merge, namespaced tag, and RubyGems publication. This does not authorize yanking, ownership transfer, a `hive-cli` version/tag/release, deployment, or merging Hive's later dependency cutover.
- **Execution profile:** Establish the Agent Runtime boundary independently on current `main`; land the self-contained package without changing Hive's released dependency graph; prove a held Hive path-dependency cutover; build once and verify the exact artifact; publish through component-scoped trusted publishing; then remotely install and verify 0.1.0.
- **Stop condition:** Stop before registry mutation if the package cannot load without Hive, the four built-in profiles cannot satisfy the documented contract, the diagnostic CLI overclaims provider health or quota, exact artifact proof fails, or RubyGems trusted-publisher authorization is absent.
- **Tail ownership:** Finish with `agent-cli-runtime` 0.1.0 remotely verified and a separate Hive cutover PR held for explicit merge direction. Any post-publication defect fixes forward under a new explicitly approved version.
- **Target repositories:** The package, release, and held Hive cutover live in `hive`; the post-publication adopter unit targets the sibling `hive-bench` repository and uses paths relative to that repository.

---

## Product Contract

### Summary

Operate a Rails-style multi-gem Ruby monorepo without turning Hive into a collection of repositories or an automatic multi-package release train.
The first package is `agent-cli-runtime`, a small adapter/compiler/probe/decoder library for Claude Code, Codex CLI, Pi, and Grok CLI plus an honest local diagnostic executable.
It remains developed beside Hive, has independent package metadata and versioning, and is consumed from its monorepo path during development.
Released `hive-cli` artifacts depend on the already-published component version normally, and release proof installs the exact built gems rather than trusting source-checkout load paths.

This plan does not promise that every internally clean component becomes a gem.
It specializes the reusable release choreography for the approved first delivery while preserving the qualification framework for later candidates.

### Problem Frame

The original extraction analysis found seven retained opportunities:

| Product-value rank | Candidate | Standalone value | Current extraction posture |
|---|---|---|---|
| 1 | RunReceipt | Durable local commands, leases, streams, recovery, and terminal receipts without a server | Strongest product; highest subsystem extraction cost |
| 2 | UserService | Safe plan/apply/status/remove for systemd-user and launchd services | Safest first internal boundary |
| 3 | Agent Artifact Firewall | Artifact custody and bounded attestation around untrusted agent spawns | Differentiated; security contract still scattered |
| 4 | Agent ABI | Provider-neutral contract for installed headless agent CLIs | Coherent profile seam; provider churn |
| 5 | Skillpack | One canonical skill projected safely to multiple agent ecosystems | Coherent mechanism; generic author schema unproven |
| 6 | Safe Agent Git Gate | Hardened Git operations and exact-object publication authority | Real security need; high maintenance burden |
| 7 | WorkLedger | Human-readable folder workflows with an append-only evidence ledger | Deepest idea; least ready and most policy-coupled |

Product rank must not become a publication schedule.
`agent-cli-runtime` is the first package because HiveBench is a concrete maintained adopter of the same profile, preflight, argv, and stream-decoding contract; RunReceipt can remain the strongest future product idea.

Ruby and Bundler already support multiple gemspecs and filesystem path dependencies inside one repository.
The hard problem is not repository layout; it is preventing a path-resolved development checkout from masquerading as a publishable artifact, and preventing an unpublished component dependency from making the released Hive gem uninstallable.

### Actors

- A1. Hive maintainers need one checkout, one issue and PR history, and one integration suite across every component.
- A2. Component maintainers need self-contained package tests, documentation, versioning, security ownership, and an explicit release path.
- A3. Hive contributors and agents need local path dependencies so changes to a component and Hive can be developed and reviewed together.
- A4. Non-Hive adopters need a normal RubyGems install, one documented require path, direct dependencies, SemVer compatibility, and no hidden `hive-cli` runtime dependency.
- A5. Release operators need an exact-commit, build-once, install-tested, approval-gated publication chain that cannot trigger Hive's root release by accident.
- A6. Existing Hive operators need the same workspace, persisted state, schemas, services, and behavior through the package cutover.

### Requirements

**Qualification**

- R1. A candidate is eligible only after its entry in `config/component-boundaries.yml` is `boundary-ready`, all production Hive consumers use the supported facade, and the internal-boundary plan's clean-load, dependency, compatibility, and integration gates pass.
- R2. Record concrete non-Hive demand: a named adopter, issue, integration, or maintained prototype that uses the boundary for a real job. Hypothetical reuse, a tidy directory, or an internal maintainer preference is insufficient.
- R3. Record the independent user journey, public Ruby surface, library-versus-CLI decision, supported Ruby and OS matrix, persistence and migration ownership, security posture, maintainer, and maintenance/release burden before choosing a public package identity.
- R4. Qualification has three honest terminal results: `package-ready`, `deferred-no-demand`, and `deferred-coupled-to-hive`. A deferred result leaves the component internal without creating empty packaging infrastructure.
- R5. The first delivery is `agent-cli-runtime`; later executions re-evaluate other candidates from current evidence instead of inheriting this selection.

**Monorepo package shape**

- R6. Keep the component in the Hive repository under `components/agent-cli-runtime/` after it reaches `package-ready`. The package owns its gemspec, `lib/`, tests, README, changelog, license metadata, and executable.
- R7. Use one documented require path and a neutral public namespace chosen at qualification. The package must not require `hive-cli`, `require "hive"`, Hive commands, stages, web code, task/config/schema constants, or Hive release metadata.
- R8. Declare every direct runtime dependency in the component gemspec. Do not rely on dependencies arriving transitively or as default gems.
- R9. Default to a library gem. Add a CLI only when the external operator journey is independently valuable and its argv, exit-status, structured-output, mutation, recovery, and approval contracts are specified and tested.
- R10. Give each published component independent SemVer and a component changelog. Do not force all packages to share `Hive::VERSION`, and do not add a monorepo package registry or release framework until at least two real gems demonstrate the need.

**Agent CLI Runtime 0.1.0 contract**

- R27. Publish the gem as `agent-cli-runtime` 0.1.0 with public namespace `AgentCliRuntime`, entry point `require "agent_cli_runtime"`, source repository metadata pointing to Hive, and executable `agent-runtime`.
- R28. The library owns immutable provider profiles, invocation compilation, local binary/version/auth-configuration probes, capability evidence, usage extraction, and result normalization for Claude Code, Codex CLI, Pi, and Grok CLI.
- R29. The `agent-runtime probe [PROVIDER|--all] [--json]` executable reports only locally observable installation, version, auth-configuration, and capability evidence. JSON uses one `schema_version: 1` envelope with a `probes` array ordered `claude`, `codex`, `pi`, `grok`; exit 0 means every requested local probe is ready, exit 1 means at least one is unavailable, and exit 64 means invalid usage. Diagnostics are bounded and secret-redacted.
- R30. Version 0.1.0 does not spawn agents, run workflows, supervise processes, retry work, accept artifacts, interpret Hive markers/stages, or claim live provider health, account quota, or credential validity from configuration presence.
- R31. Hive remains the primary in-repo consumer and HiveBench is the named non-Hive adopter proving the package contract is independently useful.

**Hive dogfood and cutover**

- R11. Develop Hive against the component through a Bundler path dependency while `hive.gemspec` declares a normal compatible released dependency for built Hive artifacts. Update both `Gemfile.lock` and `web/Gemfile.lock` when the real dependency lands.
- R12. The component package PR and Hive cutover PR remain separate. The package may land without changing Hive's released dependency graph; the cutover remains stacked or held until the component version is publicly available and remotely verified.
- R13. Temporary duplication between the internal implementation and the package is allowed only across the coordinated publication window, with parity tests and an explicit removal unit. Main must never contain two independently evolving authoritative implementations.
- R14. Hive and the component use the same state root, records, locks, schemas, service files, and compatibility fixtures. Packaging does not copy durable state or silently migrate it.
- R15. Path-selected component tests are fast feedback only. Every package or cutover PR still runs the complete relevant Hive integration gate and exact-head hosted CI.

**Artifact and release proof**

- R16. Build the component gem once from an expected protected-main commit and inspect its file manifest, metadata, require path, direct dependencies, executables, schemas, templates, and license/readme/changelog inventory.
- R17. Install the exact built gem into a clean gem home with no repository load path, no Hive gem, and no Bundler path source; exercise its public library API and CLI when present on the supported Ruby, Linux, and macOS matrix.
- R18. Prove Hive against the exact built component artifact as well as the development path dependency. Lowest and highest compatible dependency versions must follow the declared compatibility policy.
- R19. Agent CLI Runtime publication uses the protected `components/agent-cli-runtime/vX.Y.Z` tag namespace and `.github/workflows/agent-cli-runtime-release.yml`. It must not match `.github/workflows/release.yml`'s root `v*.*.*` trigger.
- R20. Path changes may trigger tests but never publication. Publication requires an expected commit, explicitly selected package and version, protected tag or equivalent approval-bearing trigger, package-scoped credentials or trusted publishing, and the already-proven artifact.
- R21. Publish the exact candidate bytes; do not rebuild between verification and publication. After RubyGems accepts the version, it is immutable: a later failure fixes forward, and yanking requires a separate explicit emergency decision.
- R22. Remote verification installs the published version from RubyGems in a fresh environment and repeats the public require/CLI smoke plus checksum and metadata checks before the component is considered released.
- R23. A Hive release may consume the new dependency only after R22 passes. Component publication and the later Hive version/tag/release remain separate explicit decisions.

**Documentation and authority**

- R24. Add component development and release instructions, package-specific changelog rules, compatibility/deprecation policy, rollback guidance, and one wiki log fragment per behavior-changing PR. Do not edit compiled `wiki/log.md`.
- R25. Choosing or registering the public gem name, selecting a version, changing a public compatibility promise, merging the coordinated cutover, creating or pushing a tag, publishing, yanking, transferring ownership, or releasing Hive stays human-authorized.
- R26. Execution without R25 authority stops at the release-ready checkpoint with no public or irreversible side effect.

### Key Flows

- F1. **Qualify Agent CLI Runtime**
  - **Trigger:** Hive's provider-neutral runtime boundary and HiveBench's duplicated harness contract identify a package candidate.
  - **Actors:** A1-A4.
  - **Steps:** Rebase the Agent Runtime boundary onto current main; verify all Hive callers use it; prove clean loading; record HiveBench demand; bind the approved public API, CLI, compatibility, and maintenance obligations.
  - **Outcome:** `agent-cli-runtime` reaches `package-ready`, or publication stops with a concrete coupling failure.
  - **Covered by:** R1-R5, R27-R31.
- F2. **Prepare the package and stacked Hive cutover**
  - **Trigger:** Agent CLI Runtime reaches `package-ready` under its approved public identity.
  - **Actors:** A1-A4, A6.
  - **Steps:** Create the self-contained component package; keep the package-only PR safe for Hive releases; prepare a separate stacked Hive path-dependency cutover; prove parity, shared state, and compatibility; hold the cutover.
  - **Outcome:** The package can land and be published without making `hive-cli` depend on an unavailable gem.
  - **Covered by:** R6-R15.
- F3. **Build and prove an exact candidate**
  - **Trigger:** The package PR is on an expected commit.
  - **Actors:** A2, A5.
  - **Steps:** Build once; inspect; install in clean environments; exercise public behavior; run Hive against the same artifact; save checksums and provenance.
  - **Outcome:** An unpublished candidate is release-ready, or the package returns to implementation without registry mutation.
  - **Covered by:** R16-R18, R24-R26.
- F4. **Publish the component with explicit authority**
  - **Trigger:** The package-only PR is merged, 0.1.0 is bound to the expected protected-main commit, and the approved RubyGems trusted publisher is configured.
  - **Actors:** A2, A5.
  - **Steps:** Create the component-scoped protected tag; verify tag/metadata/commit identity; build once; verify and publish those exact bytes through OIDC; install from RubyGems; verify remote metadata and behavior.
  - **Outcome:** `remotely-verified`, or `registry-published-fix-forward` if post-publication proof fails.
  - **Covered by:** R19-R22, R25.
- F5. **Cut Hive over after publication**
  - **Trigger:** The component version is remotely verified.
  - **Actors:** A1, A3, A6.
  - **Steps:** Rebase the held cutover; use the local path for development and the published compatible dependency for built artifacts; remove the internal duplicate; update both lockfiles; rerun artifact and full Hive integration proof; merge separately.
  - **Outcome:** Hive consumes the published gem while the monorepo remains the canonical development workspace.
  - **Covered by:** R11-R15, R18, R23-R25.

### Acceptance Examples

- AE1. Given a boundary-ready component with no named non-Hive adopter or maintained prototype, when qualification runs, then the result is `deferred-no-demand` and no `components/` directory, gemspec, or public name is created.
- AE2. Given a component that loads only after `require "hive"` or imports Hive commands/stages, when qualification runs, then the result is `deferred-coupled-to-hive` even if its focused tests pass.
- AE3. Given a package-ready candidate, when its package-only PR lands before publication, then current `hive-cli` releases remain installable because `hive.gemspec` has not yet gained the unpublished dependency.
- AE4. Given a stacked Hive cutover before publication, when CI runs, then Bundler resolves the component by path for development and exact-artifact tests install the locally built component before the Hive candidate; the cutover remains unmergeable.
- AE5. Given a built component gem, when it is installed into a fresh gem home without the repository or `hive-cli`, then its documented require path and standalone behavior work and every required schema/template is present.
- AE6. Given a changed component path, when normal CI runs, then focused package tests may be selected but no tag, RubyGems push, GitHub release, or Hive release begins.
- AE7. Given a component tag `components/example/v1.2.3`, when GitHub evaluates workflows, then the component workflow validates it and Hive's root `v*.*.*` release workflow does not run.
- AE8. Given no explicit publication instruction or selected version, when the candidate workflow completes, then it stores proof artifacts and stops without creating a tag or contacting RubyGems publication endpoints.
- AE9. Given RubyGems has accepted a version but the remote-install smoke fails, when the release is handled, then the version is not overwritten or silently yanked; the maintainer records the state and prepares a fix-forward release.
- AE10. Given the component is remotely verified, when the Hive cutover lands, then source development uses the monorepo path, built `hive-cli` declares the released dependency, both lockfiles are current, and the duplicate internal implementation is gone.

### Success Criteria

- At most one candidate is packaged per execution of this plan, and it passed every qualification gate using current evidence.
- The component is self-contained, independently installable, directly documented, and free of upward Hive dependencies.
- Hive path dogfood and exact built-artifact integration both pass against the same public contract and shared state.
- The component release trigger cannot activate Hive's release workflow, and ordinary path changes cannot publish.
- The exact `agent-cli-runtime` 0.1.0 bytes are remotely verified before Hive's dependency cutover or release.
- The held Hive cutover does not merge without its separate authority, and no Hive release is implied by component publication.

### Scope Boundaries

**Included**

- Qualification and deferral criteria for all seven retained candidates.
- One component package under `components/`.
- Independent gemspec, version file, changelog, documentation, tests, assets, and optional CLI.
- Path-based monorepo development, exact artifact proof, component-scoped release automation, and a coordinated Hive cutover.

**Deferred until a second real gem**

- A generalized component registry, dependency graph tool, release orchestrator, shared version command, or multi-package changelog system.
- Cross-component automated release ordering.

**Outside this plan**

- Separate repositories, Git submodules, vendored source copies as a permanent architecture, or npm-oriented monorepo tools.
- Publishing every retained candidate, synchronizing all package versions, or promising a public extraction roadmap.
- Auto-publishing based on path changes.
- A new external composition framework combining RunReceipt, Agent ABI, and Artifact Firewall.
- Publishing a second component, changing the approved public identity, or transferring registry ownership.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Keep one canonical monorepo.** (session-settled: user-approved — chosen over one repository per gem because integrated investigation, cross-component changes, and agent navigation are more valuable than repository-level isolation.)
- KTD2. **Publish only after a proven internal boundary.** (session-settled: user-approved — chosen over package-first extraction because a gem must expose a real contract rather than relocate accidental Hive coupling.)
- KTD3. **Keep Hive as the primary dogfood consumer.** (session-settled: user-directed — chosen over an external-first rewrite because Hive provides the first compatibility and integration pressure.)
- KTD4. **Use explicit releases, never path-change publication.** (session-settled: user-approved — chosen over automatic selective publishing because version choice and public registry mutation require deliberate authority.)
- KTD5. **Ship Agent CLI Runtime first.** (session-settled: user-approved — chosen over Attempts/RunReceipt first because HiveBench already duplicates and needs the four-provider runtime contract.) Later candidates still re-evaluate demand, coupling, risk, and ownership.
- KTD6. **Create `components/agent-cli-runtime/` only after qualification.** This keeps package-owned code, tests, metadata, and assets together without creating a general package framework.
- KTD7. **Give components independent SemVer.** `hive-cli` declares a compatible range; components do not inherit `Hive::VERSION` or require synchronized releases.
- KTD8. **Use a package-first, publish-first, cutover-last choreography.** Land the self-contained package without changing Hive's released dependency graph, publish and remotely verify it, then land Hive's dependency cutover. This avoids a period where released Hive cannot install.
- KTD9. **Dogfood both the path and the exact artifact.** Bundler path resolution keeps monorepo development fast, while clean gem installation catches missing files, undeclared dependencies, and repository-only assumptions.
- KTD10. **Build once and publish the proven bytes.** Component release follows Hive's exact-candidate discipline but uses its own workflow, tag namespace, artifact, and registry credentials.
- KTD11. **Publish a library plus one diagnostic executable.** (session-settled: user-directed — chosen over library-only because a standalone local probe is useful without Hive.) `agent-runtime` exposes the bounded R29 journey and no process-running surface.
- KTD12. **Delay package-management infrastructure until two packages need it.** One real package uses explicit Rake/workflow targets; duplication pressure from a second package justifies a registry or shared release helper.
- KTD13. **Treat public registry mutation as human-only.** Candidate automation may build, inspect, install, and attest. Name registration, version selection, tags, publication, yanking, ownership transfer, Hive release, and destructive migration remain explicit operator actions.
- KTD14. **Use RubyGems trusted publishing with exact-byte push.** Configure the official OIDC credential action in the package-scoped release job, then push the already-built `.gem`; do not use a release task that rebuilds or pushes tags.
- KTD15. **Keep provider policy injectable.** The public package owns neutral profiles and evidence values; Hive-only model defaults, skills, stages, markers, retry policy, artifact custody, and success classification remain in Hive adapters.
- KTD16. **Support Ruby 3.4 first.** Version 0.1.0 matches Hive and HiveBench's current Ruby floor (`>= 3.4.0`) and tests Ruby 3.4 on Linux and macOS; broadening the public compatibility promise requires evidence and a later release.

### High-Level Technical Design

```mermaid
flowchart TB
  B[Boundary-ready Hive component] --> Q{Demand and qualification gates pass?}
  Q -->|no| D[Remain internal with deferral reason]
  Q -->|yes| P[Package-only PR under components]
  P --> C[Exact component candidate]
  C --> G{Explicit name, version, commit, and publish authority?}
  G -->|no| H[Stop release-ready and unpublished]
  G -->|yes| R[Protected component tag, OIDC, publish exact bytes]
  R --> V[Remote RubyGems install verification]
  V --> X[Separate Hive cutover PR]
  X --> Y[Path dependency for development and released dependency for artifacts]
```

The safe dependency transition uses two pull requests:

1. **Package PR:** introduces the self-contained component, release tests, and component workflow without changing `hive.gemspec` to depend on an unpublished gem.
2. **Hive cutover PR:** dogfoods the component by path, declares the normal compatible runtime dependency, preserves any forwarding compatibility surface, deletes the former internal implementation, and updates both lockfiles. It stays stacked or held until the component is remotely verified.

The package and Hive use one public contract and one shared compatibility fixture set.
Temporary implementation duplication is bounded to this release window and protected by parity tests; it is never accepted as the final state.

### Qualification Matrix

| Gate | Required evidence | Failure state |
|---|---|---|
| Internal boundary | `boundary-ready` catalog entry and all Hive callers behind the facade | `deferred-coupled-to-hive` |
| External demand | Named adopter, issue, integration, or maintained non-Hive prototype | `deferred-no-demand` |
| Independent journey | Library or CLI use case with success, error, mutation, and recovery behavior | `deferred-no-demand` |
| Clean load | Public require works without Hive aggregate or upward constants | `deferred-coupled-to-hive` |
| Dependency direction | `hive-cli -> component`, never component -> Hive | `deferred-coupled-to-hive` |
| Compatibility ownership | Public API, persisted format, migration, SemVer, deprecation, Ruby/OS policy | `deferred-coupled-to-hive` |
| Artifact proof | Built-gem inventory, clean install, standalone smoke, Hive integration | Return to implementation |
| Maintenance ownership | Named maintainer and release/security response commitment | `deferred-no-demand` |

### Release State Model

```text
internal
  -> package-ready
  -> candidate-proven
  -> publication-authorized
  -> registry-published
  -> remotely-verified
  -> hive-cutover-merged
```

`deferred-no-demand` and `deferred-coupled-to-hive` are terminal qualification states.
Before `registry-published`, failures repair or revert without public side effects.
After `registry-published`, the version is immutable and failures move to a fix-forward state.
`remotely-verified` is required before Hive's cutover may merge or a Hive release may consume the dependency.

### Sequencing

1. Run qualification and stop immediately on an honest deferral result.
2. Bind the approved `agent-cli-runtime` 0.1.0 public identity and executable contract in package metadata.
3. Build the package-only PR and the separately held Hive cutover.
4. Add exact artifact and release-workflow proof.
5. Reach the release-ready checkpoint and confirm the RubyGems pending trusted publisher.
6. Merge the package-only PR and bind the expected main commit to `components/agent-cli-runtime/v0.1.0`.
7. Publish the exact artifact through OIDC and remotely verify RubyGems.
8. Replace HiveBench's duplicated neutral runtime pieces with the remotely verified gem in a separate adopter PR.
9. Rebase and verify the held Hive cutover; merging it and any later Hive version/tag/release are separate decisions.

### Sources and Research

- `docs/plans/2026-07-25-001-refactor-internal-component-boundaries-plan.md` defines the prerequisite internal contract.
- `hive.gemspec`, `Gemfile`, `Gemfile.lock`, `web/Gemfile`, and `web/Gemfile.lock` define Hive's current single-gem dependency and packaged-install surfaces.
- `docs/RELEASING.md` and `.github/workflows/release.yml` provide the build-once, exact-candidate, native install, explicit tag, and no-rebuild publication precedent.
- `wiki/decisions.md` ADR-031 and `wiki/modules/digest.md` record PRDigest as the existing dependency-first externalization precedent: the standalone package is the engine and Hive remains the adapter.
- Bundler's official Gemfile reference documents multiple gemspecs in one repository, filesystem `path` dependencies, and the `path 'components'` block: `https://bundler.io/v4.0/man/gemfile.5.html`.
- RubyGems' official publishing guide defines the normal gem build and push surface: `https://guides.rubygems.org/publishing/`.
- RubyGems' trusted-publishing guide defines pending publishers for a brand-new gem, OIDC identity binding, short-lived package-scoped credentials, and the required workflow/environment match: `https://guides.rubygems.org/trusted-publishing/`.
- The official `rubygems/configure-rubygems-credentials` action can configure OIDC credentials for a later explicit `gem push` and recommends pinning action commits, which preserves the build-once requirement: `https://github.com/rubygems/configure-rubygems-credentials`.
- `hive.gemspec` comments record why direct runtime dependencies and installed-gem file inventories are required instead of relying on source checkout or transitive/default gems.
- `harness/lib/profile.rb`, `harness/profiles/slate.rb`, and `harness/lib/isolation_exec.rb` in the maintained `hive-bench` repository duplicate the profile, preflight, invocation, and stream-decoding contract and establish the named non-Hive adopter.

### System-Wide Impact

- **Repository layout:** The root remains authoritative for shared CI, issues, wiki, and integration. A component owns only its package subtree and referenced shared fixtures.
- **Dependency resolution:** Development favors the component path; built and remote Hive artifacts use the published dependency. Tests must make the selected source visible so path and artifact proof cannot be confused.
- **Release topology:** Root `vX.Y.Z` remains exclusively Hive's release trigger. Component tags and workflows are namespaced, independently protected, and separately credentialed.
- **Lockfiles:** A real Hive cutover changes the root and web lockfiles. Package-only work must not leave locks pointing at an unpublished dependency on main.
- **Persistent state:** Packaging changes code ownership, not state ownership by fiat. Shared state roots, schema versions, migrations, and older-process behavior stay compatible through the cutover.
- **Security:** `.github/workflows/agent-cli-runtime-release.yml` receives short-lived OIDC authority only in the `agent-cli-runtime-release` environment. Candidate jobs have read-only registry posture and cannot publish.
- **Agents:** Agents continue navigating one repo, use package-local README/tests for focused work, and use root wiki/integration tests for cross-component behavior. Nested agent instructions are added only if package workflows materially differ.
- **Support:** A published component creates a real compatibility and vulnerability-response obligation independent of Hive's release cadence.

### Risks and Mitigations

| Risk | Mitigation or rejection signal |
|---|---|
| A neat internal seam is mistaken for market demand | Require a named adopter, issue, integration, or maintained prototype and accept `deferred-no-demand`. |
| Path tests hide missing files or dependencies | Install the exact built gem in a clean gem home with no repo path or Hive gem, inspect the file manifest, and declare all direct dependencies. |
| Hive main depends on an unpublished gem | Land package-only first, hold the separate cutover, remotely verify publication, then merge the dependency change. |
| Temporary duplicate implementations drift | Keep the window short, share/parity-test the contract fixtures, forbid unrelated changes, and delete the internal implementation in the cutover. |
| A component tag triggers Hive's release chain | Use and test a protected `components/<name>/vX.Y.Z` namespace that cannot match root `v*.*.*`. |
| Publication starts from an ordinary path change | Give candidate workflows no publish credentials and make publication depend on an explicit protected trigger plus expected commit/version inputs. |
| Verification and publication use different bytes | Build once, checksum and attest the candidate, and publish the exact retained artifact without rebuilding. |
| Registry accepted the version but later proof fails | Treat the version as immutable, record the partial release, fix forward, and require separate authority for any yank. |
| Independent versions create compatibility drift | Declare component SemVer/deprecation policy, test supported dependency bounds, and keep Hive's compatible range explicit. |
| Persistent formats strand existing Hive workspaces | Keep shared fixtures and migration ownership explicit; reject packaging until old and new consumers interoperate safely. |
| Release tooling becomes a framework project | Use explicit per-package tasks/workflows for the first gem and defer a registry/orchestrator until a second package produces real duplication. |
| Public namespace selection causes churn before demand | Choose and register the neutral name only after qualification and explicit approval. |
| A local auth file is mistaken for valid credentials or provider health | Name the observation `auth_configuration`, report only `configured` / `missing` / `not_checked`, and keep live auth, quota, and online health outside R29-R30. |
| OIDC trust is bound to an unintended workflow | Require an exact pending-publisher match for repository, workflow filename, gem name, and GitHub environment; keep `id-token: write` at the publish job only. |
| Action tags drift or are compromised | Pin checkout, Ruby setup, artifact, and RubyGems credential actions to reviewed commit SHAs in the release workflow. |

---

## Implementation Units

### U1. Establish and qualify the Agent Runtime boundary

- **Goal:** Land the provider-neutral Agent Runtime boundary on current main and record why it has earned package work.
- **Requirements:** R1-R5, R24-R31; F1; AE1-AE2; KTD1-KTD5, KTD13, KTD15.
- **Dependencies:** The owning units in `docs/plans/2026-07-25-001-refactor-internal-component-boundaries-plan.md` are complete.
- **Files:** `config/component-boundaries.yml`, `lib/hive/agent_runtime.rb`, `lib/hive/agent_profile.rb`, `lib/hive/agent_profiles.rb`, `lib/hive/agent_profiles/*.rb`, affected Hive consumers, `test/unit/agent_runtime_test.rb`, `test/unit/agent_profile_test.rb`, `test/unit/component_boundaries_test.rb`, affected consumer tests, `docs/plans/2026-07-25-002-feat-standalone-component-gems-plan.md`, `wiki/component-boundaries.md`, `wiki/modules/agent.md`, `wiki/modules/agent_profile.md`, `wiki/gaps.md`, `wiki/log.d/<timestamp>-agent-runtime-boundary.md`.
- **Approach:** Rebase the existing Agent ABI work independently of Attempts and UserService. Keep compile/probe/decode behavior provider-neutral, inject or leave Hive-only identity and skill policy at adapters, route every Hive consumer through the supported facade, promote the catalog row to `boundary-ready`, and record HiveBench's duplicated profile/preflight/argv/stream code as the maintained external adopter.
- **Execution note:** Preserve the focused characterization coverage from the existing Agent ABI branch before adapting it to current main.
- **Patterns to follow:** The component catalog's clean-load and consumer-construction contracts, and ADR-031's separation between a standalone engine and Hive adapter.
- **Test scenarios:**
  1. Each built-in profile compiles the same argv/stdin transport Hive used before the boundary.
  2. Unsupported directories, tools, model/effort, and raw arguments return typed capability evidence without silently widening permissions.
  3. Probe failures redact and bound diagnostics and never become quota or online-health claims.
  4. Usage extraction tolerates malformed and provider-specific stream events without crashing callers or fabricating unavailable counts.
  5. The boundary clean-loads without Hive commands, stages, web, task, or release code, and external callers cannot construct its listed internals.
- **Verification:** Focused Agent Runtime, AgentProfile, component-boundary, and changed-consumer tests pass; the broad Hive suite and exact-head hosted CI prove parity on current main.

### U2. Create a self-contained package-only component

- **Goal:** Establish `components/agent-cli-runtime/` without changing Hive's released dependency graph.
- **Requirements:** R6-R10, R12-R14, R24-R31; F2; AE3; KTD6-KTD8, KTD11-KTD15.
- **Dependencies:** U1 returned `package-ready`.
- **Files:** `components/agent-cli-runtime/agent-cli-runtime.gemspec`, `components/agent-cli-runtime/lib/agent_cli_runtime.rb`, `components/agent-cli-runtime/lib/agent_cli_runtime/`, `components/agent-cli-runtime/exe/agent-runtime`, `components/agent-cli-runtime/test/`, `components/agent-cli-runtime/README.md`, `components/agent-cli-runtime/CHANGELOG.md`, `components/agent-cli-runtime/LICENSE.txt`, `Rakefile`, package documentation and wiki log fragment.
- **Approach:** Extract only the neutral profile, compile, probe, capability-evidence, usage-decoding, and result-normalization mechanism. Replace upward Hive errors, secret redaction, permission CSV, model-default, auth-path, and skill-verification dependencies with package-owned values or injected callbacks. Keep the internal Hive implementation authoritative until the published cutover, and use shared fixtures/parity tests to prevent drift. Implement the R29 executable with stable JSON schema and documented exit statuses. Do not add the dependency to `hive.gemspec` in this PR.
- **Execution note:** Start with package clean-load and parity tests so upward Hive dependencies fail before source moves.
- **Patterns to follow:** Existing gemspec file-inventory and direct-dependency discipline; package-local tests that require the installed-style entry point rather than relative source files.
- **Test scenarios:**
  1. The gemspec contains complete metadata, direct dependencies, required Ruby, files, license, README, changelog, and the `agent-runtime` executable.
  2. The documented require path loads without `hive-cli`, root Hive load paths, or upward constants.
  3. Package behavior and shared compatibility fixtures match the boundary-ready Hive implementation for compile, probe, capability, usage, result, and redaction cases across all four providers.
  4. The package-only change does not alter `hive.gemspec`, root/web lockfiles, Hive runtime requires, or root release installability.
  5. `agent-runtime probe codex --json` emits the versioned schema and nonzero status for unavailable local prerequisites without exposing secrets or claiming quota/credential validity.
  6. `agent-runtime probe --all` reports every supported provider independently so one unavailable CLI does not hide the other results.
  7. Invalid providers, conflicting provider/`--all` input, and malformed options print usage and exit 64 without running a probe.
- **Verification:** Package-focused tests, gemspec/file-inventory tests, clean-process require smoke, parity tests, root `bundle exec rake test`, and exact-head hosted CI pass in a package-only PR.

### U3. Prepare the held Hive path-dependency cutover

- **Goal:** Prove Hive as the primary consumer of the package while keeping the dependency cutover separate and unmerged until publication.
- **Requirements:** R11-R15, R18, R23-R26; F2, F5; AE4, AE10; KTD3, KTD8-KTD9, KTD13.
- **Dependencies:** U2 package-only branch exists.
- **Files:** `Gemfile`, `hive.gemspec`, `Gemfile.lock`, `web/Gemfile.lock`, `lib/hive/agent_runtime.rb`, `lib/hive/agent_profile.rb`, `lib/hive/agent_profiles.rb`, `lib/hive/agent_profiles/*.rb`, focused Hive consumer tests, package/Hive shared fixtures, affected wiki pages and log fragment.
- **Approach:** Create a stacked cutover PR. Resolve `agent-cli-runtime` from `components/agent-cli-runtime` for development, declare `~> 0.1.0` in `hive.gemspec`, route Hive through `require "agent_cli_runtime"`, preserve documented `Hive::AgentRuntime`, `Hive::AgentProfile`, and `Hive::AgentProfiles` forwarding compatibility, and delete the duplicate implementation. Keep the PR held until U7 remotely verifies 0.1.0 and the user separately authorizes its merge.
- **Patterns to follow:** Current root `gemspec` dependency resolution and PRDigest's published-engine/Hive-adapter boundary.
- **Test scenarios:**
  1. Bundler selects the component path in the source checkout while `hive.gemspec` records the normal compatible dependency.
  2. Hive's focused consumers run exclusively through the package and observe the same state, locks, schemas, results, and errors.
  3. Existing documented Hive constants either forward compatibly or receive an explicit separately approved break; no silent constant disappearance occurs.
  4. Both root and web lockfiles resolve consistently.
  5. Removing the component path or locally installed candidate makes the artifact test fail rather than falling back to copied internal code.
- **Verification:** Component tests, Hive focused consumer/compatibility tests, both frozen Bundler installs, root `bundle exec rake test`, and exact-head hosted CI pass on the stacked PR; the PR remains unmerged.

### U4. Prove exact component and Hive artifacts

- **Goal:** Catch package omissions and repository-only assumptions before any public release.
- **Requirements:** R8, R14-R18, R24-R26; F3; AE5; KTD9-KTD10, KTD13.
- **Dependencies:** U2 and U3.
- **Files:** `components/agent-cli-runtime/bin/build-candidate`, `components/agent-cli-runtime/bin/verify-candidate`, `components/agent-cli-runtime/test/package_test.rb`, root packaging integration tests, held Hive candidate install tests, `.github/workflows/ci.yml`, documentation and wiki log fragment.
- **Approach:** Build one component candidate from the expected commit, inspect it, and install it into clean environments without repository load paths. Build a Hive candidate from the held cutover and install the exact component artifact before Hive, proving the normal dependency path. Exercise supported Ruby and OS targets and dependency bounds without contacting publication endpoints.
- **Patterns to follow:** Hive's release candidate build-once and private gem-home install gates; existing `test/unit/gemspec_test.rb` and installed-gem integration tests.
- **Test scenarios:**
  1. The built gem contains every declared Ruby file, schema, template, executable, README, changelog, and license and excludes tests or repository-only files as intended.
  2. A clean gem home requires and exercises the component without Bundler path sources or `hive-cli`.
  3. A missing direct dependency, omitted asset, accidental root-relative path, or upward Hive require fails the installed smoke.
  4. The exact component artifact satisfies the built Hive candidate and all shared state/compatibility tests.
  5. Lowest and highest supported component dependency versions follow the documented compatibility policy.
  6. Linux and macOS Ruby 3.4 jobs install the same gem bytes and produce the same public API/CLI results.
- **Verification:** Exact checksums and provenance identify one component artifact, clean install smokes pass on supported Ruby/Linux/macOS targets, the Hive candidate consumes those bytes, and full hosted CI is green.

### U5. Add an isolated component release workflow and runbook

- **Goal:** Make release mechanics explicit, package-scoped, build-once, and unable to trigger from ordinary code changes.
- **Requirements:** R16-R26; F3-F4; AE6-AE9; KTD4, KTD7-KTD10, KTD13.
- **Dependencies:** U4.
- **Files:** `.github/workflows/agent-cli-runtime-release.yml`, `components/agent-cli-runtime/bin/release-preflight`, component workflow contract tests, `docs/RELEASING.md`, package README/changelog, wiki release documentation and log fragment.
- **Approach:** Define the protected `components/agent-cli-runtime/vX.Y.Z` trigger, validate package/tag/version/expected-main-commit identity, build the candidate once, run U4 proof, checksum the exact artifact, configure short-lived RubyGems credentials through the official OIDC action in the `agent-cli-runtime-release` GitHub environment, and push that retained file without rebuilding. Test that root Hive tags cannot enter this workflow and component tags cannot enter `.github/workflows/release.yml`. Document the exact pending trusted-publisher fields, pre-publication, partial-publication, remote verification, fix-forward, and emergency-yank states.
- **Patterns to follow:** `.github/workflows/release.yml` exact candidate and install gates, but not its Hive web/Homebrew/AUR/GHCR publication chain.
- **Test scenarios:**
  1. Only the exact protected component tag shape with matching package version and reachable protected-main commit passes preflight.
  2. Root `vX.Y.Z`, ordinary branches, pull requests, path changes, malformed tags, and mismatched versions cannot reach publication.
  3. Candidate and install jobs have no RubyGems publish authority; only the approval-bearing publish job can access package-scoped credentials.
  4. Publication consumes the exact checksummed candidate artifact and does not rebuild.
  5. Workflow contracts prove component tags do not match Hive release triggers and vice versa.
  6. A dry candidate run completes without registry mutation and preserves enough evidence for the release-ready checkpoint.
  7. The trusted-publisher tuple is exactly `ivankuznetsov/hive`, `agent-cli-runtime-release.yml`, `agent-cli-runtime`, and `agent-cli-runtime-release`.
- **Verification:** Workflow contract tests, local candidate scripts, component/Hive artifact gates, root `bundle exec rake test`, and exact-head hosted CI pass without publishing.

### U6. Reach the release-ready checkpoint

- **Goal:** Produce a complete candidate and held cutover, then verify the account-side pending trusted publisher before tag creation.
- **Requirements:** R1-R31; F1-F3; AE1-AE8; KTD1-KTD16.
- **Dependencies:** U1-U5.
- **Files:** Package and cutover PR descriptions/evidence, candidate checksums and workflow artifacts, package changelog draft, release checklist, affected wiki pages and `wiki/gaps.md`.
- **Approach:** Revalidate qualification and maintenance ownership, 0.1.0 metadata, exact commit and candidate identity, artifact proofs, workflow isolation, package-only PR safety, held cutover status, compatibility policy, and rollback/fix-forward instructions. Confirm the RubyGems pending trusted publisher targets `ivankuznetsov/hive`, workflow `agent-cli-runtime-release.yml`, gem `agent-cli-runtime`, and environment `agent-cli-runtime-release`. Merge only the package PR under the authority in the Goal Capsule; keep the Hive cutover held.
- **Patterns to follow:** Hive's explicit release-decision boundary in `docs/RELEASING.md`.
- **Test scenarios:**
  - **Test expectation: none —** this unit changes no runtime behavior; any defect returns to its owning implementation unit.
- **Verification:** Package and cutover PRs are review-ready on exact tested heads, candidate proof is reproducible, no publication credentials were used, RubyGems has no new version, and the next irreversible action is visibly blocked on explicit owner authority.

### U7. Publish and remotely verify agent-cli-runtime 0.1.0

- **Goal:** Publish the exact candidate and prove the public registry/install surface before Hive depends on it.
- **Requirements:** R16-R31; F4; AE7-AE9; KTD4, KTD7-KTD10, KTD13-KTD16.
- **Dependencies:** U6, the package-only PR merged to protected main, and the approved pending trusted publisher configured on RubyGems.
- **Files:** Component version file and changelog, exact package tag/release metadata, immutable candidate and checksum evidence, remote-install verification record, wiki release log fragment.
- **Approach:** Confirm the exact protected-main candidate already declares 0.1.0, create `components/agent-cli-runtime/v0.1.0`, let the release workflow build once and publish that verified file through OIDC, and install the exact public version in fresh environments. If registry mutation occurs and later proof fails, stop Hive cutover and fix forward under a separately approved version.
- **Patterns to follow:** Hive's exact-tag release verification and PRDigest's dependency-before-Hive precedent.
- **Test scenarios:**
  1. Remote RubyGems metadata matches the approved name, version, checksum, dependencies, Ruby requirement, source, and MFA/trusted-publishing expectations.
  2. Fresh remote installs on the supported matrix require and exercise the public API/CLI without the repository or Hive.
  3. Re-running publication for the same version is rejected; no workflow attempts to overwrite accepted bytes.
  4. A failed post-publish smoke records `registry-published-fix-forward` and blocks U8.
- **Verification:** RubyGems serves the exact proven version and all remote smokes pass. No Hive tag or release is created.

### U9. Adopt the published runtime in HiveBench

- **Goal:** Prove the public package in the maintained non-Hive harness without moving HiveBench's isolation, scoring, timeout, or benchmark policy into the gem.
- **Requirements:** R2, R7-R10, R22, R24, R27-R31; F1, F4; KTD3, KTD5, KTD11-KTD16.
- **Dependencies:** U7 is `remotely-verified`.
- **Target repo:** `hive-bench`.
- **Files:** `Gemfile`, `Gemfile.lock`, `harness/lib/profile.rb`, `harness/profiles/slate.rb`, `harness/lib/isolation_exec.rb`, focused profile/preflight/stream tests, repository documentation and release notes.
- **Approach:** Add the normal `agent-cli-runtime` 0.1 dependency, adapt HiveBench's slate values into public profiles, use the package compiler and probe/evidence values, and replace only duplicated neutral usage decoders. Keep Docker command transport, egress, timeouts, provider-cost accounting, model slate, result parking, and benchmark scoring in HiveBench.
- **Execution note:** Use an isolated HiveBench worktree because live benchmark artifacts and active runs are user-owned state.
- **Patterns to follow:** HiveBench's existing injectable preflight seams and isolation runner boundary.
- **Test scenarios:**
  1. Every current Claude, Codex, and Pi slate entry compiles the same provider argv/model/effort/output transport as before adoption.
  2. Missing binaries, old versions, and missing auth configuration remain fail-soft cell preflight results rather than uncaught package exceptions.
  3. Claude, Codex, and Pi stream fixtures produce the same token/cached/model values; HiveBench-specific dollar cost stays local.
  4. Docker isolation, timeout classification, provider limit text, and scoring behavior are unchanged and do not call the package's diagnostic executable.
  5. A clean HiveBench install resolves `agent-cli-runtime` from RubyGems rather than a sibling path.
- **Verification:** Focused HiveBench tests, its broad suite, clean Bundler install, and exact-head hosted CI pass in a separate adopter PR.

### U8. Land the Hive cutover after remote verification

- **Goal:** Make the released component the production dependency while retaining path-based monorepo development.
- **Requirements:** R11-R15, R18, R23-R25; F5; AE10; KTD1-KTD3, KTD7-KTD9, KTD13.
- **Dependencies:** U7 is `remotely-verified` and the user explicitly authorizes merging the coordinated Hive cutover. A later Hive version/tag/release still requires separate direction.
- **Files:** Held U3 files and PR, `Gemfile.lock`, `web/Gemfile.lock`, compatibility shims, former internal source deletion, Hive release/install contract tests, wiki/component docs and log fragment.
- **Approach:** Rebase the held cutover onto current main, pin the compatible range to the remotely verified component, keep the monorepo path source for development, remove temporary duplication, rerun source and built-artifact integration, and land the cutover separately. Preserve forwarding compatibility where promised and record any restart guidance for long-running Hive processes.
- **Patterns to follow:** PRDigest as standalone engine with a thin Hive adapter and Hive's dependency/file-inventory tests.
- **Test scenarios:**
  1. Source checkout resolves the component path and built `hive-cli` resolves the published dependency.
  2. Fresh `hive-cli` candidate installation downloads the component normally and runs all affected commands.
  3. Existing state/schema/service fixtures remain readable and writable under the documented compatibility policy.
  4. Both lockfiles are current and frozen installs pass.
  5. No duplicate authoritative implementation or accidental component source copy remains inside the Hive gem.
- **Verification:** Focused component/Hive tests, both frozen installs, exact built Hive install smoke, root `bundle exec rake test`, and exact-head hosted CI pass. The cutover PR may merge only under the explicit authority above; no Hive version, tag, release, or deployment is implied.

---

## Verification Contract

| Gate | Applicability | Command or evidence | Passing signal |
|---|---|---|---|
| Qualification | U1 and final audit | Completed qualification matrix backed by catalog, tests, demand artifact, maintainer, and compatibility policy | Exactly one `package-ready` candidate or an honest terminal deferral with no packaging scaffold. |
| Package focused tests | U2 onward | Package-local test task executed from `components/agent-cli-runtime/` and from the root Rake integration | Public behavior passes without Hive load paths. |
| Clean require | U2 onward | Fresh Ruby process with only the installed component gem | The documented require path loads; `hive-cli`, Thor commands, web, stages, and Hive constants are absent. |
| File/dependency inventory | U2-U7 | Gem specification and built-artifact inspection | All runtime files/assets and direct dependencies are present; repository-only and test files are excluded as intended. |
| Path dogfood | U3 onward | Root Bundler resolution and focused Hive consumer tests | Development selects `components/agent-cli-runtime` and Hive uses the package facade. |
| Exact component artifact | U4-U7 | Build once, checksum, clean private install, public API/CLI smoke | One retained artifact passes supported Ruby/Linux/macOS proof with no repo load path. |
| Exact Hive artifact | U4 and U8 | Install the exact component gem then the exact Hive candidate in a clean gem home | Hive invokes the packaged component and all affected commands work. |
| Lockfiles | U3 and U8 | Frozen root and web Bundler installs | `Gemfile.lock` and `web/Gemfile.lock` agree with source path and released dependency policy. |
| Release workflow contract | U5-U7 | Workflow parser/contract tests and a non-publishing candidate run | Component and Hive tags are disjoint; candidate jobs cannot publish; publish uses the proven bytes. |
| Broad local checkpoint | Every behavior-changing PR | `bundle exec rake test` | The default Hive suite passes; exhaustive coverage remains CI-owned unless packaging machinery itself changes coverage. |
| Hosted CI | Every PR and release candidate | Exact-head GitHub Actions checks | All required checks are green on the reviewed commit; full Hive integration remains mandatory. |
| Remote registry | U7 | Fresh RubyGems metadata lookup and install on supported targets | Name, version, checksum, dependencies, and behavior match the approved candidate. |
| HiveBench adopter | U9 | Clean RubyGems dependency install and focused harness parity tests in `hive-bench` | The maintained non-Hive harness consumes the public library while retaining benchmark policy locally. |
| Documentation | Every behavior-changing PR | Package docs, component wiki, release guide, compatibility policy, and one `wiki/log.d/` fragment | Documentation describes the actual source/artifact/release state and compiled `wiki/log.md` is untouched. |

---

## Definition of Done

### Default completion under this plan's current authority

- Exactly one boundary-ready component was qualified, or the execution ended with `deferred-no-demand` or `deferred-coupled-to-hive` and created no empty package framework.
- `agent-cli-runtime` has a self-contained `components/agent-cli-runtime/` subtree, `AgentCliRuntime` public namespace, `require "agent_cli_runtime"` entry point, `agent-runtime` executable, direct dependencies, package-local tests, documentation, compatibility policy, and named maintenance owner.
- The package-only PR does not make current Hive releases depend on an unpublished gem.
- The separate Hive cutover dogfoods the component by path, declares the future released dependency, preserves shared state and compatibility, updates both lockfiles, and remains held.
- One exact component artifact passes inventory, clean install, supported platform, public API/CLI, dependency-bound, and exact Hive candidate integration proof.
- Component and Hive release triggers are disjoint, candidate automation has no publication authority, and ordinary path changes cannot publish.
- Package and cutover PRs are review-ready on exact tested heads, release and rollback/fix-forward instructions are complete, and 0.1.0 is not tagged until the pending trusted publisher and protected-main commit are confirmed.
- No tag, RubyGems publication, yank, ownership change, Hive version, Hive release, deployment, or cutover merge occurred without a separate explicit user instruction.

### Additional completion after explicit publication and cutover authority

- The package-only PR merged to protected main and the approved component tag bound the approved version to the exact tested commit.
- RubyGems serves the exact proven artifact, remote metadata and clean installs match it, and any partial publication failure is recorded and fixed forward.
- HiveBench consumes 0.1.0 from RubyGems for neutral profile, probe, compile, and decode behavior while retaining isolation, limits, costs, and scoring policy.
- Only after remote verification, the separate Hive cutover removed temporary duplication, retained path-based monorepo development, declared the compatible released dependency, updated both lockfiles, and passed exact built-artifact plus full Hive integration proof.
- The component and Hive have independent versions and changelogs; no later Hive tag, release, or deployment is assumed.
- Package, wiki, release, and compatibility documentation match the final state, and no abandoned scaffold, duplicate implementation, leaked credential, stale candidate artifact, or unrelated workspace change remains.
