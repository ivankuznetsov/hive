# 2026-10-29 — Successor PR when the owned PR was closed unmerged

- hivedev C4's owner closed its placeholder PR #6 unmerged. After the task
  re-ran, open-pr failed every time with `github_publication_revision_hosted_terminal`
  ("pull request became terminal before the publication revision was hosted").
  The healer re-dispatched it every one to two minutes with no way forward.
- `GithubPublication::Controller#supersede_closed_pr` now starts a successor
  publication when the owned PR is CLOSED (not merged) and lacks the current
  head. The push is leased to the branch's last published head, or to an
  absent branch. The new head must contain that head. The controller then
  creates a new PR, and the closed one is recorded as `superseded_pr`. The
  state contract allows a non-nil `expected_remote_oid` only when it matches
  `superseded_pr.published_head_oid`.
- A branch moved by someone else still fails closed, and so does a merged PR.
- Updated [[stages/open-pr]].
