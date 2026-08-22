# 2026-08-20 — Patrol Fix deterministic publication

**Area:** Patrol Fix workflow, Git/GitHub publication, receipts, Done state

**Action:** Added the deterministic `5-publish` controller and strict hosted-PR
receipt. A lower `Hive::GithubPublication` state machine now persists stable
publication identity and digests before effects, uses an expected-absence Git
lease, distinguishes intent from attempted-unknown outcomes, inventories every
GitHub PR state through complete pagination, and adopts only one exact
controller-marker/title/body/repository/base/branch/head match. Pre-existing
branches, foreign or ambiguous PRs, incomplete inventories, secrets, and stale
review/worktree identity fail closed without overwrite or blind redispatch.

`pr.md` and the canonical receipt are durable before the receipt-gated move to
Done. Cleanup runs afterward and can add a bounded diagnostic without revoking
completion. Local bare-remote and injected-gateway tests cover lost push/create
responses, beyond-page-one adoption, hosted states, branch ownership, immutable
creation base, revalidation, replay, cleanup failure, and zero-mutation import.
Import requires the same full canonical receipt payload; the earlier five-field
PR summary is no longer completion authority. Cleanup also rebinds exact
controller custody before removal, so a replayed receipt cannot target a
tampered worktree pointer.
Coding Draft PR and both legacy Patrol publisher suites remain unchanged and
green. No live GitHub mutation was performed.
