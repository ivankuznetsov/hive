## [2026-07-24T23:25:06Z] workflow publish — close validation and recovery seams

- Bound the local Honeycomb lint identity to the pinned upstream policy,
  fixture corpus, expected findings, and immutable local contract. The analyzer
  now mirrors pinned secret/PII, deny, command/network extraction, permission,
  network-reason, suppression-request, and bounded-input rule IDs without
  executing package content.
- Rejected symlinked intermediate authoring paths, preserved high-risk packages
  as reviewable submissions, and kept install/spawn runtime admission separate
  from publication disclosure validation.
- Made receipt progress, write-once remote authority, and lifecycle observations
  monotonic. Exact PR recovery now verifies fork parent/owner, head
  repository/branch/OID, commit parent, package tree, and PR base; a digest-
  matching external branch is adoptable only after those checks.
- Kept retained lifecycle evidence observable when a newer lint policy blocks
  continuation, while stopping any new fork, push, or PR mutation. Rechecked
  the immutable target path immediately before the first push.
- Closed `hive-workflow-publish.v2` error variants so kind, process exit code,
  retryability, and required remote recovery identity cannot contradict one
  another. Added strict SemVer and structured lint fingerprint coverage.
- Focused unit and integration tests cover each boundary with injected
  transports and isolated state; no live GitHub mutation or release action was
  performed.
