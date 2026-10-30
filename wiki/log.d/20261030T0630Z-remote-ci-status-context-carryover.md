# 2026-10-30 — Review GitHub gate no longer carries commit statuses to a new head

- `Review::RemoteCi::Runner` seeds the checks it expects on the published
  head from the PR's pre-publication rollup. It also carried commit statuses
  (`StatusContext`) over. hivedev's `bin/ci` posts a `signoff` status only for
  a commit already on the remote, and review runs it before publishing. So
  the old head's `signoff` was expected on a new head that never gets one,
  and every hivedev review CI gate polled `gh pr view` until the one-hour
  settlement timeout (`ci_github_error`). Observed on hivedev F2 and on the
  b2327cf7 pin raise on 2026-10-29/30.
- Only push-triggered check runs (`CheckRun`) carry over now, from the
  baseline and from earlier settled heads in the same run. Statuses still
  count on the exact head when they are present: a failed status fails the
  gate, and a pending one keeps it waiting.
- Test: `test/unit/stages/review/remote_ci_test.rb`
  (`test_runner_does_not_wait_for_baseline_commit_statuses_on_a_new_head`).
