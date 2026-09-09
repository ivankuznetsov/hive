# 2026-08-30 — Reconcile reworked draft publications

Open-PR re-entry now fast-forwards an existing controller-owned draft after
review or artifact rework. Hive retains the original durable publication as the
ownership anchor, revalidates the exact hosted PR and remote head, requires the
hosted history to retain that anchor and the new local head to retain the hosted
head, then pushes with an expected-OID lease. Lost push responses converge from
remote observation; identity changes, rewritten history, divergence, remote
conflicts, and terminal PRs missing the revision remain fail-closed.

The shared password-assignment scanner now distinguishes whole shell variable
references such as `MINIO_ROOT_PASSWORD=${SECRET_ACCESS_KEY}` from embedded
literal credential material. This prevents safe environment indirection in an
exact diff from blocking publication without weakening mixed-value detection.

See [[stages/open-pr]] and [[modules/secret_patterns]].
