---
title: Component boundaries
type: reference
source: config/component-boundaries.yml, test/support/component_boundary_contract.rb
created: 2026-07-25
updated: 2026-08-21
tags: [architecture, components, boundaries, monorepo]
---

**TLDR**: The machine-readable component catalog defines supported entry
points, ownership, dependencies, consumers, state, recovery, and clean-load
requirements. Hive remains the first consumer. Patrol migration/effect evidence
is no longer a component; Patrol Fix is the only retained Patrol component
boundary.

## Current catalog

| Component | State | Current entry point | Narrative context |
|-----------|-------|---------------------|-------------------|
| Provider Health | `candidate` | `require "hive/provider_health"` → `Hive::ProviderHealth` | [[modules/provider_health]] |
| Provider Routing Policy | `candidate` | `require "hive/provider_routing"` → `Hive::ProviderRouting` | [[modules/provider_routing]] |
| Provider Routing Operations | `candidate` | `require "hive/provider_routing/operational_projection"` → `Hive::ProviderRouting::OperationalProjection` | [[modules/provider_routing]] |
| Patrol Fix Workflow Core | `boundary-ready` | `require "hive/patrol_fix"` → `Hive::PatrolFix` | [[modules/patrol]] |
| Attempts admission / future RunReceipt | `candidate` | `require "hive/attempts/api"` → `Hive::Attempts::API` | [[modules/attempts]] |
| UserService | `boundary-ready` | `require "hive/user_service"` → `Hive::UserService` | [[modules/user_service]] |
| Agent ABI | `boundary-ready` | `require "hive/agent_runtime"` → `Hive::AgentRuntime` | [[modules/agent_profile]] |
| Agent Artifact Firewall | `boundary-ready` | `require "hive/artifact_firewall"` → `Hive::ArtifactFirewall` | [[modules/protected_files]] |
| Skillpack | `boundary-ready` | `require "hive/agent_skills"` → `Hive::AgentSkills` | [[commands/setup-agents]] |
| Safe Agent Git Gate | `boundary-ready` | `require "hive/agent_git_gate"` → `Hive::AgentGitGate` | [[modules/agent_git_gate]] |
| WorkLedger | `boundary-ready` | `require "hive/work_ledger"` → `Hive::WorkLedger` | [[state-model]] |
| Workflow Creator Values | `boundary-ready` | `require "./packaging/live_agent_skills/workflow_creator_text_safety"` → `HiveLiveAgentProof::WorkflowCreator::TextSafety` | [[component-boundaries]] |
| Workflow Creator | `boundary-ready` | `require "./packaging/live_agent_skills/workflow_creator_evidence"` → `HiveLiveAgentProof::WorkflowCreatorEvidence` | [[component-boundaries]] |
| Workflow Creator Live Orchestration | `boundary-ready` | `require "./packaging/live_agent_skills/workflow_creator_live_setup"` → `HiveLiveAgentProof::WorkflowCreatorLiveSetup` | [[component-boundaries]] |
| Workflow Creator Execution | `boundary-ready` | `require "./packaging/live_agent_skills/workflow_creator_execution"` → `HiveLiveAgentProof::WorkflowCreatorExecution` | [[component-boundaries]] |

`candidate` means the seam is mapped but not yet supported for extraction.
`boundary-ready` means dependency direction, construction rules, and
clean-process loading are enforced. It does not authorize a gem, package,
version, tag, or release.

## Graph audit

The catalog retains fifteen components: eleven are `boundary-ready`; Provider
Health, Provider Routing Policy, Provider Routing Operations, and Attempts
remain `candidate`. There are no migration exceptions.

```mermaid
flowchart LR
  skillpack[Skillpack] --> agent_abi[Agent ABI]
  workflow_execution[Workflow Creator Execution] --> workflow_core[Workflow Creator]
  workflow_live[Workflow Creator Live Orchestration] --> workflow_execution
  workflow_live --> workflow_core
  workflow_core --> workflow_values[Workflow Creator Values]
  patrol_fix[Patrol Fix Workflow Core] --> git_gate[Safe Agent Git Gate]
  attempts[Attempts] --> provider_health[Provider Health]
  attempts --> provider_routing[Provider Routing Policy]
  routing_operations[Provider Routing Operations] --> attempts
  routing_operations --> provider_health
  routing_operations --> provider_routing
```

All other dependencies are explicit lower-level Hive primitives. Every retained
entry point has focused clean-load proof, and the production construction scan
enforces internal-owner boundaries.

## Patrol Fix boundary

`Patrol Fix Workflow Core` owns strict source snapshots, direct admission,
task manifests, semantic decisions, task materialization, exact worktree
generations, validation/review/publication receipts, route transitions, and
projections. Thin ordinary and Architecture adapters translate source records
and reserve them directly in one project `AdmissionStore`.

The component has no discovery scheduler, occurrence journal, effect delivery,
migration ownership, shadow comparison, cutover, rollback, status schema, or
remote transport. It depends downward on Safe Agent Git Gate and normal task
capture. The workflow-owned Publish stage composes the separate
`Hive::GithubPublication` mechanism.

## Boundary enforcement

The contract validates:

- unique component IDs and owned paths;
- declared component and lower-level Hive dependencies;
- explicit public values and forbidden internal constructions;
- named construction sites where a consumer must instantiate an internal
  collaborator;
- clean-process entry-point loading;
- candidate versus boundary-ready migration-exception rules;
- consistency between this inventory and the YAML catalog.

## Backlinks

- [[architecture]]
- [[modules/patrol]]
- [[testing]]
