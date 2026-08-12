## 2026-08-11 — Close bound-answer review gaps

**Why:** Review pass 2 found fail-open or misleading edges around blank and
reattached bindings, batch web writes, post-write Telegram stage movement,
Unicode compatibility folding, legacy answer decoding, and unbounded marker
lock acquisition.

**Action:** Bound writes now require a real presented binding; Telegram
`/answer` keeps exact project identity and refuses unbound restart replies;
web batches preflight every binding before writing. Post-write Telegram
inventory tolerates normal stage advancement while acknowledging and clearing
the conversation. The parser enforces one-based slots, fingerprints with NFC,
and decodes structural escapes only under an explicit v1 answer header, while
the writer handles lone-CR files and bounded marker locks. Dead supervisor and
exact-writer branches were removed, and the same-user unauthenticated binding
trust boundary is documented.

**Evidence:** Focused command, parser, writer, marker, Telegram router/handler/
supervisor, and Rails task-mutation tests cover ambiguous and missing-task
no-write receipts, deeper identity/workflow rechecks, legacy answer fidelity,
compatibility-distinct fingerprints, bounded lock contention, whole-batch web
preflight, exact Telegram project routing, and post-write stage movement.
