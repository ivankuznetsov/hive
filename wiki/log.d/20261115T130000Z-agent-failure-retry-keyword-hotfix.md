---
title: Hotfix, the daemon crashed on every Patrol Fix agent retry
type: fix
created: 2026-11-15
updated: 2026-11-15
tags: [daemon, attempts, patrol-fix, incident]
---

After #1659 was deployed (dogfood 6886c8ac1), the daemon crash-looped. Every
tick that reached a Patrol Fix agent-failure retry raised
`ArgumentError: unknown keyword: :agent_failure_retry`:

- the daemon dispatcher passes `agent_failure_retry:` to its attempt
  dispatcher;
- production wires that dispatcher as `Attempts::API` → `ConfiguredDispatcher`
  → `Attempts::Dispatcher`;
- only the innermost layer accepted the keyword.

Unit tests passed because they stubbed or used the inner dispatcher directly.

Dogfood was rolled back to b6d600107 by repointing `dogfood-current` under the
deploy lock. The runtime database schema was unchanged and the preflight
passed.

- `Attempts::API#dispatch_request` and `ConfiguredDispatcher#dispatch_request`
  now pass `agent_failure_retry:` through.
- **Regression tests:** the delegation tests assert that the keyword arrives
  (the configured-dispatcher stub uses strict keywords). A contract test
  requires every `dispatch_request` layer to accept the same keyword set, so
  future drift fails CI instead of the daemon. Both tests fail against the old
  `api.rb`.
