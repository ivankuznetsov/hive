## 2026-08-20 — Patrol Fix adds independent review and replayable routing

**Action:** Added one independent lightweight review stage over the exact
controller-resolved finding, clean worktree diff/head, fix receipt, and
validation receipt. The reviewer returns only the strict
`publish|rework|escalate|reject|blocked` report; all repository and finding
content remains delimited untrusted data.

**Recovery:** Review receipts become durable before route actions. Rework and
operator reopen advance generation under the stable slug lock so a new review
decision occupies a new tuple. Rework rotates and reuses the existing worktree
without carrying old validation; review-stage reopen may explicitly carry an
unchanged fix/validation pair. The default permits two completed rework cycles,
then removes that route from the prompt and parser. Interrupted folder moves,
generation changes, and route commits reconcile without another model decision.

**Escalation:** Inbox and Review escalation keep the lightweight origin parked
and create or reconcile exactly one reciprocal standard coding task through the
lower-level task-capture service. Replay repairs missing links and performs no
GitHub issue mutation.
