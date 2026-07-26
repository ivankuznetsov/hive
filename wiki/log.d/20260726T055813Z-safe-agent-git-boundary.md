## 2026-07-26 — Safe Agent Git Gate boundary

- Promoted `Hive::AgentGitGate` to a boundary-ready, clean-loadable internal
  facade over hardened Git reads, exact detached materialization, remote
  observation, and expected-OID publication.
- Kept raw `Hive::ManagedGit` argv/process execution private and added a
  production-consumer guard against bypassing the facade.
- Added immutable read, observation, materialization, and publication values
  plus typed request, operation, conflict, materialization, and publication
  errors.
- Routed managed `Hive::Gh`, AgentReport, draft-PR handoff, refactor-patrol
  publication, and exact Worktree analysis materialization through the facade.
- Exact publication now resolves an immutable local OID, requires exact remote
  OID or absence authority, pushes under that lease, and independently observes
  the remote before returning a non-secret before/after receipt.
- Added real bare-remote and hostile-helper tests; no gem, version, tag,
  release, or standalone publication was added.
