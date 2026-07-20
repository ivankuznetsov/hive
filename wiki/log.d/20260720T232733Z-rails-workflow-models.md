---
title: Model reviewed workflow changes in Rails
date: 2026-07-20
tags: [web, rails, architecture, workflows, security]
---

Hive Web now represents lifecycle rows as `Workflow` models and a reviewed
install, update, or removal as a `WorkflowChange`. These models own the native
lifecycle seam, typed row predicates, dry-run identity, expiring signed
receipt, operation-specific consent, separate security-escalation consent, and
application outcome.

The established workflow URLs and helpers are unchanged, but preview and
application requests now enter small namespaced controllers through standard
`create` actions. The operation is read from the matched route instead of
submitted form/query parameters, and a regression proves an injected
`operation` field cannot change the lifecycle action. `WorkflowsController`
now owns only collection display and authored-workflow creation.

The Rails scan also re-identified the already-audited task-media `send_file`
false positive after task lookup moved into the model, so its stale Brakeman
fingerprint was refreshed without changing the containment justification.
