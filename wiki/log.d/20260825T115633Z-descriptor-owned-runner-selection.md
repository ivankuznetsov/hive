# 2026-08-25T11:56:33Z — Descriptor-owned stage runner selection

## What changed

`Hive::Stages::Resolver` no longer dispatches on workflow identity plus a
hard-coded stage-name table. Each `Hive::Workflow::Stage` now derives an
internal EXECUTION STRATEGY key (`Stage#execution_strategy`):

- an explicit per-stage `runner:` pin wins (Ruby-descriptor-only field,
  never parsed from project YAML);
- otherwise the kind maps to a generic strategy via
  `Workflow::GENERIC_KIND_STRATEGIES` (`agent → :agent`, `council → :council`,
  `controller → :controller`);
- everything else (inert, human, nil) derives nil and raises `StageError`.

`Workflows::Coding::DESCRIPTOR` pins all nine bespoke runners with `runner:`
keys; `Workflows::PatrolFix::DESCRIPTOR` pins every stage (including terminal
`done`) to the controller runner. `Resolver::CODING_RUNNERS` became
`RUNNERS`, keyed by strategy, and the `Hive::Workflows.coding_id?` guard and
name-first precedence are gone from dispatch.

## Why

The old resolver leaked coding identity into dispatch: any descriptor whose id
passed `coding_id?` had its `kind:` declarations overridden by name-collision
with the hard-coded table, and non-coding workflows only escaped misrouting via
a special-case guard. Runner ownership now lives entirely in each descriptor.

## Affected pages

- [[commands/run]] — Stage routing section rewritten.
- [[stages/agent]] — brainstorm/plan note updated to the runner-pin mechanism.
- [[modules/workflows]] — Runner Selection section rewritten to describe the
  `Stage#execution_strategy` dispatch (`RUNNERS` keyed by strategy,
  Ruby-only `runner:` pins, generic kind mapping) in place of the deleted
  workflow-ID/name-first routing.

## Tests

- `test/unit/stages/resolver_test.rb`: regression pins kind-over-name-table
  under a coding id, strategy-key drift guard against declared descriptor
  strategies, and every-coding-stage-pins-a-runner.
