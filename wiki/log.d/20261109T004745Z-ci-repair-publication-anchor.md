## 2026-11-09 — Review/CI-repair pushes advance the publication anchor

- Symptom (PR #1419): a hosted-CI repair commit reached GitHub, but review
  ended `REVIEW_ERROR reason=review_publication_failed publication_reason=pr_head_moved`
  and `github-publication.json` kept the previous `published_head_oid`.
- Cause 1: `Review::Publication#confirm!` read the PR `headRefOid` once, about
  2-3 seconds after the leased push. GitHub had not updated it yet, so the
  receipt-proven push was reported as an external head move. The cached
  publisher then turned that into the stage error.
- Cause 2: review publication pushed through `AgentGitGate` without touching
  the task's publication record, so the anchor never advanced.
- Fix: new `GithubPublication::Controller#publish_fast_forward!` writes the
  exact intent before the leased push and advances `published_head_oid` after
  observing the remote. `Review::Publication` wraps every push in it when the
  record exists. Confirmation waits a bounded 1+2+3+5+8 s only while the PR
  reports a strict ancestor of the pushed head. Unrecorded history fails closed
  as `publication_record_<code>`; other external moves still fail at once.
