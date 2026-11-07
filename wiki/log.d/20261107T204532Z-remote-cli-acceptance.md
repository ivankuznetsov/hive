---
date: 2026-11-07T20:45:32Z
title: Remote CLI acceptance and operator recovery
---

Added a two-installation acceptance fixture with separate client/server homes,
same-named projects, a real TLS proxy restricted to `/api/v1`, Rails API and
independent daemon processes. Deterministic native workers prove actual task
advancement, durable replay after a severed response and server restart,
operation progress after transient-result cleanup, and continued execution
after token revocation. Checkout inventories prove remote mutations leave the
client project untouched. Scope-only, all-project, project-restricted,
owner/loopback interlock and denied administrative routes are exercised.

The server-context regression exposed detached native children consulting the
operator's saved remote client selection. Attempt wrappers and native workers
now explicitly select `local` in their execution argv while retaining the
recorded logical argv for capability checks. A selected remote client context
cannot retarget accepted server work. Local name-generation, daemon, bot,
one-shot and TUI Hive children also receive an explicit local selection; their
logical command metadata and non-Hive executable arguments are preserved.
Managed daemon/web/bot/babysitter startup definitions and daemon/babysitter
re-exec also explicitly retain local custody while preserving process command
signatures. Older installed definitions require the documented existing
force-install procedure; no installed service was migrated during execution.

Real HTTP acceptance also exposed binary-tagged Rack header strings: the
adapter now validates an UTF-8 copy of `Idempotency-Key` before passing it to the
unchanged native key contract. Invalid header encoding remains a typed 400.
Binary token names likewise fail validation before registry serialization.

Added operator guidance for TLS-only API forwarding, owner provisioning
(including hosted workspace creation), receipt/daemon prerequisites, independent
scopes, explicit local overrides, remote content selectors, high-entropy retry
keys, retained cross-token key conflicts, and incident response. Existing local
verbs support ingress shutdown, per-token revocation, pending queue inspection
and verified installation-wide quiescence. They cannot enumerate and selectively
cancel every historical operation for a token; this remains in [[gaps]].

Local transport/daemon acceptance and local CLI boundary suites pass together:
9 tests, 533 assertions. The API plus browser-authentication/task-model
regression checkpoint passes: 161 tests, 1,114 assertions. Focused attempt
launcher/supervisor checks pass: 62 tests, 323 assertions. The delivered receipt
principal, replay, unresolved-state, retention and serving-installation checks
passed before mutation integration; no receipt adapter, store expansion or
runtime database migration was introduced.

The final focused collection passes 4,143 tests and 23,194 assertions. Targeted
CLI, context/token, shared-service and startup follow-ups close its remaining
coverage gaps. Combined per-file evidence passes the repository's exact-line
policy for all 46 changed library files: 11,062/11,062 executable lines. The
local aggregate report records collection provenance and source hashes. This
is focused line-coverage evidence; exhaustive coverage remains a CI gate.

The broad checkpoint ran 959 test files: 16,253 tests, 308,294 assertions,
5 failures, 25 errors and 14 skips. It is not a green checkpoint. Reported
OpenCode errors reproduce through the unchanged baseline process-custody code
when this host returns `ESRCH` for `/proc/<pid>/environ`. The wiki read-only
assertion also detected concurrent writes and subsequently passed in isolation
(2 tests, 52 assertions). One failed worker log was overwritten by the parallel
runner's later component job, limiting classification of its earlier failures.
These verification limits are retained in [[gaps]].

Exhaustive coverage and packaged/performance merge gates remain CI checks. Live
NAS/Hivebox, production proxy and manual network-capture evidence are
unavailable. No release, deployment or review pass is part of this execution
stage.
