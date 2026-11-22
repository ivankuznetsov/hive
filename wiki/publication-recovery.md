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
The reconciled `published_head_oid` and the task branch HEAD are part of the
retry's failure fingerprint for operator-owned review gate blocks, so that
retry starts a fresh series instead of parking as a repeat of the pre-merge
conflict. Hive's auto-rebase never rewrites a published branch while it is in
review (`published_review_branch`), so the lease-push path above applies only
to other stages.

## External fast-forward of a review branch

An operator (or a delegated agent) may push commits straight onto a task's
published PR branch. When the owned worktree head is a strict ancestor of the
PR head, that is a fast-forward, not a conflict. Before 2026-11-22
`ReviewPublicationRecovery.classify` knew only `equal`, `ahead` and
`divergent`, so it recorded this as `divergent`/`remote_conflict`. The
advertised `workflow.retry` then wedged on the suspended review grant
(`review_grant_evidence_changed`). That was the hivedev F4 task: 35
operator commits on top of worktree head `6ede822b`.

Classification now has four outcomes:

| Classification | Meaning |
|---|---|
| `equal` | The PR names the local head. |
| `ahead` | The PR head is an ancestor of the local head; only local commits are missing. |
| `behind` | The local head is a strict ancestor of the PR head; the PR holds every local commit. |
| `divergent` | Each side has commits the other lacks. |

`Review::Publication#publish!` never pushes over `behind` and never adopts it
mid-run, because the run's passes and grant are bound to the old head. It stops
with `REVIEW_ERROR reason=review_publication_failed
publication_reason=remote_fast_forward_adoptable`. Operational status names the
case in `review_publication.remediation`.

Adoption happens in the routine retry path. `RecoveryCoordinator#resume` holds
the task lock and runs `Hive::ReviewFastForwardAdoption#adopt!` before grant
validation. This applies to `review_publication_failed` markers whose
publication reason is `remote_fast_forward_adoptable` or the legacy
`remote_conflict`. Daemon retries and an operator's `workflow.retry` both reach
it. The adoption runs these steps:

1. It reads the owned worktree pointer. The pointer's branch and path must match
   the recorded evidence, and HEAD must be the reviewed `local_head` or a
   descendant of it.
2. It resolves the managed origin push URL, which must be the PR repository, and
   re-observes the PR branch live. The recorded `remote_head` is informational
   only.
3. The observed commit must be present locally, classify must return `behind`,
   and the worktree must be clean.
4. `AgentGitGate.fast_forward` re-observes the remote immediately before
   `git merge --ff-only <exact oid>` and verifies HEAD, the branch and a clean
   worktree afterwards. It never resets, forces or rebases.
5. `PassArchive.retire!` ends the old review generation. It is the same reset as
   a rewind or an outcome-evidence rework. Grants get an audit `expiry` with
   `expiry_reason=remote_fast_forward_adopted`. Numbered passes and grant or
   completion receipts move to
   `reviews/archive/<utc>-remote-fast-forward-<oid12>/`. A `retirement.json`
   records `before_oid` (the reviewed head), `after_oid`, the branch and the
   PR URL.
6. When the task has an attempt binding, it also writes a `recovery_recorded`
   task-journal activity with payload `adopted_remote_fast_forward`.

The coordinator then clears the marker as usual. The next run starts at pass 1
on the adopted head and cannot reuse grant evidence or findings bound to the
old head. `github-publication.json` needs no `publication-reconcile`: the old
anchor is an ancestor of the adopted head, so the next leased publication
advances it.

These cases keep their previous behavior:

- If the PR head is not a fast-forward (divergent, or the worktree has
  local-only commits), adoption returns nil. Grant validation and ordinary
  recovery then decide, as before.
- If the PR branch was deleted, or the PR names the reviewed head again,
  adoption returns nil as well.

When adoption is provable but unsafe, the request is blocked with
`remote_fast_forward_refused`. The remediation starts with the reason:

- `dirty_worktree` (owner `operator`): the remediation names `git status`. Hive
  never discards edits.
- `remote_object_unavailable` (owner `operator`): the remediation gives the
  exact `git -C <worktree> fetch origin <branch>`.
- `publication_identity_changed`, `worktree_unavailable` or `git_unavailable`
  (owner `operator`). `git_unavailable` covers unsafe repository-local Git
  config and a merge that failed or could not be verified.
- `remote_moved`, `remote_observation_unavailable` or `remote_unavailable`
  (owner `hive`): these are transient, and the next daemon tick re-observes the
  PR branch.

A crash after the merge is safe to retry. HEAD then equals the PR head, and
retirement reuses the archive whose `retirement.json` matches.

Other `classify` consumers: `TaskClosure#retained_fix_details` now labels a
PR reference ahead of the worktree `behind`/`published`. Closure still
requires the operator decision. `confirm_absence` still marks only `ahead` as
`unpublished`. Push guidance is still emitted only for `ahead`.

## Stacked base retarget

A task PR stacked on its prerequisite's branch is retargeted by GitHub when the
prerequisite PR merges (todero #100: stacked on `typed-lists-foundation-…`,
retargeted to `main` after #99 merged). Open-PR then builds its request from
`main`, because `DependencySnapshot.stacked_base` drops a delivered
prerequisite. Before 2026-11-19 the recorded `base_branch` made every revision
`github_publication_identity_drift`, and `publication-reconcile` had the same
requirement, so the task could only be closed.

`GithubPublication::Controller#adopt_base_retarget` now accepts the new base
inside `publish!` and `reconcile_inspected!` only when all of these hold:

- the record is `pr_observed` with a PR, host/repository/branch/draft are
  unchanged, and only `base_branch` (optionally `creation_base_oid`) differs;
- the complete branch inventory holds exactly one live PR, the recorded one
  (number and URL as `revision_owned?` matches them), open, and already based on
  the requested branch. Hive never retargets a PR itself;
- the old base cannot host a stack: no open same-repository PR has it as head,
  and one merged into the requested base, or merged elsewhere while the old
  branch is now absent from the remote. This is a second `list_pull_requests`
  call with the old base as head branch plus, only for the second case, a
  remote branch observation;
- the request's `creation_base_oid` is an ancestor of its change base (the merge
  base of the requested base and HEAD), which is an ancestor of HEAD. A
  squash-merged prerequisite therefore keeps drifting until Hive's rebase
  reconciles the stale `base_oid` (see [[modules/rebase]]).

On success it revalidates the request (`:retarget` phase), atomically rewrites
`base_branch` and `creation_base_oid` in the record and its `pr` observation,
appends a bounded `base_retargets` entry (from/to base and creation base, the
base PR number/URL, `merged_into_new_base` or `merged_and_deleted`, time), and
continues through the ordinary revision path. The PR-body marker
(`id=… base=…`) and `publication_id`, body and marker digests stay as creation
provenance. Hive does not rewrite the hosted body, and revision ownership reads
number, URL and branches, never the marker. The marker only matters to
`exact_owned?` before a PR is observed, and in Patrol's format-only regex.
Any other base change still blocks as `identity_drift`.

A task parked on the old drift recovers through ordinary retry once the fixed
build runs: a new runtime digest rearms the deterministic park once, and a
fresh `hive act workflow.retry PROJECT:SLUG --observation TOKEN` also works.
No `publication-reconcile` step is needed.

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

Validate runs publication's commit secret scan
(`GithubPublication.commit_secret_findings`) before its commands. Findings route
the patch back to Fix with redacted path/line/rule feedback while the shared
rework budget lasts, then park for the operator. A Publish `secret_detected`
block can be released with
`hive act workflow.secret_rework PROJECT:SLUG --observation TOKEN --confirm`.
If the blocked commits still reproduce, the patch returns to Fix; if they no
longer do (a stale block, for example after an exact-fingerprint exception),
Publish reopens in a new generation and rescans title, body, and commits.
See [[modules/patrol]] for the gate, bound, and action contract.

## Exact secret-scan exceptions

Betterleaks still owns detection. Operator-reviewed false positives can be
listed as native exact fingerprints in `betterleaks.ignore` under Hive's config
home (normally `~/.config/hive`). Each line binds a commit, path, rule and line.
Task-authored ignore files and inline suppression comments remain ineffective.
An exception does not exempt other occurrences, future commits, titles or bodies.
Never use a blanket rule or directory exception for a fixture finding. The
Patrol Fix secret rework never writes this file; for an agent-authored test
credential, rework the fix instead of adding an exception. After an operator
adds a reviewed exact fingerprint, `workflow.secret_rework` on the parked task
finds the range clean and reopens Publish instead of reworking.

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
