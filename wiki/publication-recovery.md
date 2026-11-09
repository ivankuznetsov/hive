# Publication and validation recovery

An observed PR is owned by its repository, base/head branch, number and URL.
Editing its title/body or advancing its HEAD does not change that identity.
The initial publication record retains its original provenance; `published_head_oid`
tracks the latest confirmed hosted revision separately. Ordinary publication still
requires ancestry from that revision and an exact remote push lease.

Coding tasks with an existing `pr.md` can import its recorded URL only when the
complete live PR inventory agrees on repository and branches, and the local
revision contains the hosted head. A matching branch name alone is insufficient.

Hive's auto-rebase writes an exact `pending_rewrite` before its leased push and
atomically advances the publication anchor after observing the new remote head.
A lost push response is reconciled from that intent. GitHub and a local file
cannot participate in one transaction; this is crash-resumable reconciliation,
not a claim of cross-system atomicity.

Review fix and hosted-CI repair pushes (`Review::Publication`) use the same
anchor through `GithubPublication::Controller#publish_fast_forward!`: the exact
`{before_oid, after_oid}` intent is written before the gate's leased push and
`published_head_oid` advances once the remote branch is observed at the new
head. The record must still admit the push (owned branch, anchor an ancestor of
the leased remote head, new head a descendant of it); otherwise review fails
closed with `publication_reason=publication_record_<code>`, for example
`publication_record_revision_history_rewritten`. A previous intent is superseded
only while the remote still hosts its `before_oid`; a lost acknowledgement is
recorded by the next publication. Tasks without `github-publication.json`
(ad-hoc reviews) keep the plain leased push.

GitHub updates a PR's `headRefOid` asynchronously after a push. Exact-head
confirmation therefore waits a bounded 1+2+3+5+8 seconds while the PR still
reports a strict ancestor of the receipt-proven head. Any other head is an
external move and reports `pr_head_moved` immediately.

Unknown external rewrites remain inspection-required. After comparing the old
and current patches, an operator can use:

```sh
hive publication-reconcile TASK --project PROJECT --pr PR_URL --head FULL_INSPECTED_HEAD --json
```

This task-locked command requires a clean owned worktree and matching live PR
head, reruns secret scanning, and changes only the local publication record.
It does not push, edit GitHub, clear a failure marker, or approve code. Normal
workflow retry and validation remain responsible for subsequent advancement.

Any manual push to a task branch (for example the merge commit a
`base_conflict` recovery asks for) leaves `github-publication.json` behind the
PR head, so the next review reports `pr_head_moved`. Run
`hive publication-reconcile` with the pushed full SHA before `workflow.retry`.

## Patrol Fix

Independent review uses the same disposable exact-HEAD materialization as
validation. The prompt carries the exact base, head and digest, not the whole
diff; the reviewer reads the patch from Git in that checkout. This avoids
embedding megabytes of dependency deletions in the launch prompt. Dependency
installation cannot dirty the authoritative fix worktree;
the source snapshot is still checked after review to reject concurrent changes.

A clean changed HEAD detected before review or publication returns the same
task to `3-validate` in a new generation. The transition preserves the worktree
and all old receipts, captures the current fix, and reruns actual validation
and independent review. Dirty work remains preserved for repair. Changes during
review/publication never inherit the old validation or approval.

## Exact secret-scan exceptions

Betterleaks still owns detection. Operator-reviewed false positives can be
listed as native exact fingerprints in `betterleaks.ignore` under Hive's config
home (normally `~/.config/hive`). Each line binds a commit, path, rule and line.
Task-authored ignore files and inline suppression comments remain ineffective.
An exception does not exempt other occurrences, future commits, titles or bodies.
Never use a blanket rule or directory exception for a fixture finding.

### Upstream content merged into the task branch

The commit scan (`SecretScanner.git_findings`) walks `--full-history
--diff-merges=separate <scan base>..<head>`. Publication passes the PR base
branch as `upstream_branch` (resolved as `refs/remotes/origin/<branch>`, then
the local branch). With an upstream tip resolved, the scan excludes commits
already on upstream (`^<upstream>`), and a finding attributed to a merge commit
is dropped only when a parent that is an ancestor of upstream already carries
the same rule and secret digest at that path. Merging `origin/<default>` into a
task branch therefore no longer re-reports upstream fixtures against the merge
commit, while task commits and conflict-resolution content stay reported. An
unset/unresolvable upstream, no merge base, or a head already on upstream keeps
the full unscoped scan; failed ancestry or commit reads raise `Unavailable`
(publication blocks as `secret_scan_unavailable`), and an unreadable upstream
blob keeps the finding. Patrol Fix draft-PR handoff is unchanged: its base is
pinned to the current base tip, so it cannot contain an upstream merge.

Operational status preserves a receipt-bound controller failure and its owner
ahead of the generic no-progress scheduler brake. A controller's lack of a text
marker is not evidence that its agent failed to produce one.

## Review publication evidence

Review publication uses the safe Agent Git Gate independently from hosted CI.
Evidence belongs to the attempted HEAD: a changed-HEAD attempt clears prior
publication and identity evidence even when the new attempt fails. Clearing
guardrail withholding invalidates the cached attempt at the same HEAD.
The owned path/branch and open, same-repository PR identity must agree. Only an
ahead-only branch is publishable; divergence requires operator reconciliation.
A gate receipt proves the exact branch ref reached the requested head. A failed
PR API cross-check retains that publication proof but leaves verification pending.
Confirmation checks local HEAD and branch both before and after remote identity
validation. Concurrent local movement retains publication proof but prevents
verified completion.
Rejected publication is `unpublished` only after an independent remote observation;
unobservable failures remain `unknown`.

Review markers carry versioned `rp_*` evidence with URL-safe base64 JSON values,
so paths, full commit IDs and shell-escaped commands survive marker formatting.
Recovery recipes refresh operational status and select only the intended task's
current `workflow.retry` action. An ineligible action stops the recipe; it cannot
advance a stage. Draft readiness is conditional on publication, exact-head
verification and a current secret scan; normal finalize remains the default.
