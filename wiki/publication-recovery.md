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

Unknown external rewrites remain inspection-required. After comparing the old
and current patches, an operator can use:

```sh
hive publication-reconcile TASK --project PROJECT --pr PR_URL --head FULL_INSPECTED_HEAD --json
```

This task-locked command requires a clean owned worktree and matching live PR
head, reruns secret scanning, and changes only the local publication record.
It does not push, edit GitHub, clear a failure marker, or approve code. Normal
workflow retry and validation remain responsible for subsequent advancement.

## Patrol Fix

Independent review uses the same disposable exact-HEAD materialization as
validation. Dependency installation cannot dirty the authoritative fix worktree;
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

Operational status preserves a receipt-bound controller failure and its owner
ahead of the generic no-progress scheduler brake. A controller's lack of a text
marker is not evidence that its agent failed to produce one.
