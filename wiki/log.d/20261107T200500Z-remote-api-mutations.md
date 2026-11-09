---
date: 2026-11-07
title: Durable scoped remote mutations and operation progress
---

Added typed JSON task capture, canonical action, opaque-handle answer and
guarded approval endpoints. Every POST requires an idempotency key. Existing
native receipts bind the full installation/token principal; replay preserves
the original admission after stage advancement. Force-derived effects remain
local with fixed guidance. API answer writes reuse the bounded literal state
reader under the native mutation lock.

Added operation lookup in an already-authorized project's existing receipt
namespace. Write-only tokens can inspect their own acknowledgements; other
principals require read. Durable attempt correlation survives transient
dispatch cleanup, with command outcome separate from worker progress and
explicit settled/result-expired states. No new result store or schema is used.

Native tests exercise a detached approval, cleanup and durable lookup. A real
Rails-over-TCP fixture drops an accepted response, restarts against the same
database, and verifies keyed replay and lookup from a new HTTP client.
The same transport fixture proves a slow native detached worker continues
after its accepted caller socket closes, while new clients observe progress.
Explicit empty or whitespace owner values now retain the owner-blank audit
diagnostic and local token-setup guidance.
