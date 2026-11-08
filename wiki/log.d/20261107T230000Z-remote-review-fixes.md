# 2026-11-07 — Harden remote admission and bounded reads

Review fixes validate installed workflow IDs before lookup, preserve context
spellings inside new-task prose, cache process-local installation identity, and
settle guaranteed recovery refusals as failed receipts. Shared workflow effect
verification now lives below remote orchestration and composes approval guards.

Remote registries use bounded lock acquisition and private client file custody.
Read handles have entry/byte limits and authenticated scope-aware stale detection
after eviction. Status mints one cursor after page sizing, preserves unavailable
projects, supports CLI continuation, and ignores transient activity in its digest.
Logs redact URL userinfo and native bearers. Artifact fallback validates limits
before source reads. Structured browser creation retains display-name generation;
API creation leaves that work to the server workflow. Approval diagnostics retain
exact replay guards; remote operational mode and version errors fail honestly.

Focused unit/API/CLI regressions cover these boundaries; subprocess acceptance
checks use explicit worker ordering rather than round-trip timing. The canonical
operating skill documents remote routing, handles and operation recovery. The
coverage-shard web dependency gap is repaired by a67eb1f2d9; hosted CI acceptance
and external deployment evidence remain separate verification obligations.
