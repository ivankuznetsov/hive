---
title: Hive::AgentSupport
type: module
source: lib/hive/agent_support.rb, lib/hive/agent_support/
created: 2026-08-25
updated: 2026-08-25
tags: [agent, provider, boundary, selective-loading, pi, opencode, codex, grok]
---

**TLDR**: `Hive::AgentSupport` is a small convention loader for optional
built-in provider behavior. It has no registry objects, policy hierarchy,
cache, or process host. Selecting Pi, OpenCode, Codex, or Grok loads only that provider;
selecting an unmigrated provider returns `nil` and preserves its current path.

## Boundary

The data-only `BUILTINS` map is the complete discovery surface, and the small
`DEFAULT_PROMPT_STYLES` table preserves custom-profile CLI compatibility
without loading a provider. A provider
root declares cohesive behavior and lazily exposes larger facets by constant:

- `Runtime` compiles provider-specific managed policy while the generic runtime
  remains the process and cleanup owner.
- `Skills` owns provider discovery, package inventory, and diagnostics.
- `SetupAdapter` is a Skillpack-owned subclass of the public lazy
  `Hive::AgentSkills::Adapter` and stays physically beside its provider facets.
- The Pi root owns its message protocol, native model rules, credential
  location/token schema, capture interface, and plan-review exceptions.
- OpenCode additionally owns its typed configuration, bounded run/export
  transaction, launch-scope translation, route observation normalization,
  exact-route/default-model policy, and completion-protocol exception.
- Codex owns its native reviewer, managed-runtime and evidence permissions,
  path-qualified reads, skill/plugin inventory, setup, credential, model,
  effort, and invocation rules. The generic runtime still materializes output
  schemas; `Hive::Reviewers::Runtime` owns its subprocess and findings writes,
  and the reviewer receives its generic stage host rather than loading
  orchestration or process custody into the provider package.
- Grok owns its terminal event protocol, auth precedence and environment,
  native model discovery, managed bubblewrap argv, skill/plugin inventory,
  runtime provenance checks, and setup operations.

Generic callers resolve the selected support once at their existing seam and
use the named facet. They do not switch on a migrated provider. Loading the
profile catalog loads none of Pi, OpenCode, Codex, or Grok; selecting one loads its small
root/configuration, while execution, skills, and setup remain lazy.

Core authority does not move: Hive still starts and reaps processes, writes
credentials and durable artifacts, admits evidence, and performs workflow
transitions. This refactor relocates existing provider decisions; it does not
add security hardening or create a separate gem.

## Gate

`test/unit/agent_support_test.rb` starts clean Ruby processes to prove
unselected-provider isolation and lazy facet loading. It also scans current
production Ruby for migrated-provider branches and legacy helper names outside
the support namespace, and rejects upward dependencies from support into
orchestration layers. Every provider phase requires non-positive raw and
substantive production Ruby LOC versus its exact previous passed commit.

## Backlinks

- [[modules/agent_profile]]
- [[commands/setup-agents]]
- [[component-boundaries]]
