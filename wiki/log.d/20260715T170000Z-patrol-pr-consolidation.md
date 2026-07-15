# Consolidate merge-worthy Patrol PRs

**Action:** Reconciled the non-overlapping, merge-worthy findings from the July 15 Patrol queue
onto current `main`, then reviewed the combined boundary instead of independently rebasing and
testing every stale Patrol branch.

**Result:** Git/GitHub babysitter reads now share stricter argument parsing, immutable
per-invocation GitHub authentication views, prompt suppression, lazy-fetch protection with an
explicit Git-version preflight, working-tree diff and verbose-status denial, and race-safe skip
logging. Duplicate and superseded Patrol patches can close against one validated merge.

**Coverage:** Focused dry-run tests exercise the combined safety boundary, including prompt
behavior on a TTY, consumed `gh api` option values, legacy Git diagnostics, auth-view cleanup,
verbose status, and skip-log pathname races.
