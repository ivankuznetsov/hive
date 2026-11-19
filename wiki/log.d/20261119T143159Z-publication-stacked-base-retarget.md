---
title: Publication accepts GitHub's retarget of a stacked task PR
type: fix
created: 2026-11-19
updated: 2026-11-19
tags: [publication, open-pr, dependencies, github, recovery]
---

todero task `shopping-lists-quantities-units-and-261105-54f2` published PR #100
stacked on `typed-lists-foundation-to-do-261105-4e88`. The foundation PR #99
merged into `main`, and GitHub retargeted #100 to `main`. After a re-plan and
re-execute, open-pr requested base `main` (the prerequisite is delivered, so
`DependencySnapshot.stacked_base` no longer applies). Every attempt then failed
`github_publication_identity_drift` ("publication identity changed: …
base_branch …"). `publish!` takes the revision path only when the recorded
`base_branch`/`creation_base_oid` equal the request, and `reconcile_inspected!`
had the same requirement. The task could only be closed with evidence.

- `GithubPublication::Controller#adopt_base_retarget` runs in `publish!` and
  `reconcile_inspected!` before the revision check. It adopts the requested
  base only if every condition holds: the record is `pr_observed` and only the
  base changed; the recorded PR (exact number/URL/branch match) is the only live
  PR on the branch, open, and already based on the requested branch; no open PR
  has the old base as head, and a same-repository PR from it merged into the new
  base, or merged elsewhere with the old branch now gone from the remote; and
  the creation base is an ancestor of the request's change base, which is an
  ancestor of HEAD.
- On adoption it revalidates (`:retarget`), atomically rewrites `base_branch`
  and `creation_base_oid` in the record and its `pr` observation, and appends a
  bounded, validated `base_retargets` trail entry. Then the normal
  `reconcile_revision` fast-forward runs. The PR-body marker, `publication_id`,
  and body/marker digests stay as creation provenance, because Hive does not
  rewrite the hosted body and revision ownership never reads the marker.
- Any other base change still blocks as `identity_drift`. Hive never retargets
  a PR.
- Recovery: a build with a new runtime digest rearms the deterministic park
  once. A fresh `hive act workflow.retry` also works. No
  `publication-reconcile` step is needed.

**Docs:** [[publication-recovery]], [[stages/open-pr]] (the fast-forward bullet
no longer claims title/body markers are identity),
[[commands/publication-reconcile]], [[modules/task_dependencies]], [[gaps]].

**Tests:** `test/unit/github_publication_test.rb`. The tests cover: a retarget
after the base merged is adopted and replays without another probe; a creation
base reconciled onto the new base is adopted; a PR GitHub did not retarget
still drifts; an old base that is unmerged, open, reopened, merged elsewhere
but still present, or merged from a fork still drifts; a base merged elsewhere
whose branch is deleted is adopted through `reconcile_inspected!`; a different
or closed PR on the branch still drifts; a squash-merged base still drifts; and
malformed trails are `state_corrupt`.
