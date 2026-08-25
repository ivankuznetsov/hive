---
title: Hive::AgentSupport
type: module
source: lib/hive/agent_support.rb, lib/hive/agent_support/
created: 2026-08-25
updated: 2026-08-25
tags: [agent, provider, boundary, selective-loading, pi]
---

**TLDR**: `Hive::AgentSupport` is a small convention loader for optional
built-in provider behavior. It has no registry objects, policy hierarchy,
cache, or process host. Selecting Pi loads `Hive::AgentSupport::Pi`; selecting
an unmigrated provider returns `nil` and preserves its current generic path.

## Boundary

The data-only `BUILTINS` map is the complete discovery surface. A provider
root declares cohesive behavior and lazily exposes larger facets by constant:

- `Runtime` compiles Pi-specific managed and evidence runtime policy while the
  generic runtime remains the process and cleanup owner.
- `Skills` owns Pi discovery, package inventory, and diagnostics.
- `SetupAdapter` is a Skillpack-owned subclass of the public lazy
  `Hive::AgentSkills::Adapter` and stays physically beside the Pi facets.
- The Pi root owns its message protocol, native model rules, credential
  location/token schema, capture interface, and plan-review exceptions.

Generic callers resolve the selected support once at their existing seam and
use the named facet. They do not switch on Pi. Unselected providers do not
load Pi or its Skills/Setup facets.

Core authority does not move: Hive still starts and reaps processes, writes
credentials and durable artifacts, admits evidence, and performs workflow
transitions. This refactor relocates existing provider decisions; it does not
add security hardening or create a separate gem.

## Gate

`test/unit/agent_support_test.rb` starts a clean Ruby process to prove
unselected-provider isolation and lazy facet loading. It also scans current
production Ruby for Pi branches and legacy Pi helper names outside the support
namespace, and rejects upward dependencies from support into orchestration
layers. The pilot additionally requires non-positive raw and substantive
production Ruby LOC versus its exact base before another provider can move.

## Backlinks

- [[modules/agent_profile]]
- [[commands/setup-agents]]
- [[component-boundaries]]
