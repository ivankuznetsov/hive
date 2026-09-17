---
pr_url: https://github.com/ivankuznetsov/hive/pull/886
pr_number: 886
head_oid: 790eda15099dfa479b98d6265915db7b3d5427fe
---

## Summary

- Hive can now install reviewed, project-local modules through preview-bound lifecycle transactions, while existing Honeycomb workflow commands remain compatibility projections.
- Patrol and Architecture Patrol can run through first-party module adapters with durable event/decision records, redacted operational status, Web lifecycle controls, and legacy command/state compatibility coverage.
- Migration keeps legacy patrols as the sole mutator and makes shadow/cutover evidence explicit; this draft intentionally does not claim the live parity gate or production cutover is complete.

Session-settled decisions carried from planning: one generalized module contract (user-directed, over patrol-only or parallel packages); project-local ownership (user-directed, over user-wide precedence); reviewed immutable catalog sources (user-directed, over arbitrary sources); preview-bound install consent (user-directed, over a separate enable step); active/previous executable generations with separate runtime state (user-directed); three named events plus schedules (user-directed); 0.x patrol compatibility (user-directed); and shadow-gated mutator cutover (user-directed, over fixture-only or immediate replacement).

## Test plan

- [x] Module E2E scenarios: 4/4 passed.
- [x] Focused runtime, lifecycle, migration, and adjacent Ruby suites passed (691 runs, 4,950 assertions in the broad adjacent run).
- [x] Rails unit/integration suites passed (186 runs, 1,030 assertions).
- [x] Root and Web RuboCop, Brakeman, bundler-audit, and `git diff --check` passed.
- [ ] Hosted exact-head CI and review remain pending for this draft.

## Notes for reviewer

The module lifecycle is intentionally fail-closed where native packaged-workflow admission cannot prove a safe path. The accompanying shadow report also records three blockers before live cutover evidence can begin: capability enforcement has not yet reached every legacy side-effect gateway, migration lacks a durable reservation-to-spawn barrier, and legacy schedulers do not yet feed immutable production decision snapshots into the comparator. The required seven-day / ten-comparable-decision observation window therefore remains at zero; this PR must not be treated as cutover or release authority.

## New concepts

### Executable generations versus runtime history

Module updates retain only an active and previous executable generation, while attempts, decisions, checkpoints, and patrol artifacts remain in a separate durable runtime ledger. This makes an activation rollback change code and configuration without rewinding operational history.

| Concern | Generation store | Runtime ledger |
| --- | --- | --- |
| Rollback | Restore prior executable pointer | Preserved unchanged |
| Retention | Active + previous only | Historical evidence remains inspectable |
| Failed activation | Candidate removed with bounded diagnostic | Decisions and attempts retained |

Hive uses this separation so patrol recovery evidence cannot be lost or replayed when a module candidate is rejected. It is not appropriate where executable behavior cannot be pinned or nonterminal work lacks a complete persisted execution snapshot.

<!-- COMPLETE pr_url=https://github.com/ivankuznetsov/hive/pull/886 is_draft=true -->
