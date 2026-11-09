---
title: Shared remote command admission and semantic readers
date: 2026-11-07
---

Added structured, nonprinting command seams for remote creation, workflow
actions, literal answers and approval. API commands bind the existing durable
receipt to the installation/token principal. Literal-answer writes now forward
their idempotency key. Browser idea capture and approval use the same
nonprinting seams, and operational action execution no longer changes cwd.

Long workflow effects enter the existing durable daemon queue with their
authorized effect and principal in its payload. Remote actions cannot derive
force or pass arbitrary argv; retries construct only a canonical installed
workflow command. API admission waits for a committed receipt before a worker
may start, and the daemon closes the original receipt pin after completion or
rejection through existing dispatch-result acknowledgement.

Detached-worker tests found two important boundaries: the caller receipt has
already completed admission when workflow effects begin, and attempt admission
changes task-journal bookkeeping included in an operational observation token.
Workers therefore keep the persisted receipt reference without reusing its
closed writable effect, and revalidate unchanged domain inputs plus the exact
authorized effect under the command lock. Input, marker, workflow and stage
changes still reject execution. No receipt store, table or column was added.

The new shared readers reuse the native semantic workspace and existing
bounded artifact, correlated-log and owned-worktree diff implementations.
Verification includes actual detached approval and action workers with a
deterministic provider, rejection after a real post-queue input change, retry
admission, answer replay after advancement and the existing domain suites.
