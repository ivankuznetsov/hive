# 2026-10-02 — Publication ignores a foreign closed PR on the task branch

- hivedev C2's stacked PR #7 (base: C1's branch) was closed by GitHub when
  C1's branch was deleted at merge. It could not be reopened because Hive had
  since rebased and force-pushed C2's branch. Every `open-pr` retry then
  stopped at `github_publication_pr_identity_conflict`:
  `reconcile_pull_requests` treated every PR ever opened for the head branch
  as a competing identity.
- A CLOSED PR that the current publication does not exactly own is now
  ignored as history. Open and merged foreign PRs still conflict, and the
  exact-owned rule is unchanged.
