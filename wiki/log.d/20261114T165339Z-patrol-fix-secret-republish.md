---
date: 2026-11-14
type: feature
---

`workflow.secret_rework` now releases stale Patrol Fix secret blocks.

On dogfood, three of four blocked todero fixes were refused with "the current secret scan reports no commit findings": their Betterleaks 1.8.1 blocks no longer reproduced on the same HEAD. Publish still returned `parked` on the old receipt, so the only offered action was closure.

- **Routing:** the action re-runs the publication commit scan under the task lock. Findings still route to rework. A clean range now applies the new `republish` Transition route (`Transition#apply_secret_republish!`): a new generation in place in `5-publish`, rotated custody, and a publish-stage `reopen` (operator `operator:secret-republish`, outcome = the block, carrying exactly the block's review receipt).
- **Approval:** `Publish` accepts that carried review as its approval only when the block was bound to it (`SecretRework.republished_review` / `republish_authority?`). Publish's full title/body/commit scan then decides: publish, or a fresh block.
- **Status:** every current secret block (title/body included) is now `available`. Status still reads only receipts. The one action picks rework or republish at execution, so it is never refused because of the scan result. `UNELIGIBLE_BLOCK` and the eligibility fields are gone.
- **Idempotency:** a replayed token returns `already_republished`. `hive-act.v2` adds the `republished` / `already_republished` statuses and `findings: 0`. `hive-patrol-fix-receipt.v1` admits the republish reopen shape.
- No scanner exceptions are written; receipts stay redacted.
