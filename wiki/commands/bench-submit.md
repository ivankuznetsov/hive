---
title: hive bench submit
type: command
source: lib/hive/commands/bench_submit.rb
created: 2026-06-14
updated: 2026-07-22
tags: [command, bench, corpus]
---

**TLDR**: `hive bench submit SLUG [--project NAME]` extracts a completed
(`9-done`) task into a [hive-bench](https://github.com/ivankuznetsov/hive-bench)
corpus entry and opens a submission PR. A low-friction producer for the
benchmark — it reuses hive-bench's own extractor and runs a local secret-token
preflight, aborting before any PR if a secret is found.

## Behavior

1. Resolves `SLUG` to a `9-done` task across registered projects (`--project`
   to disambiguate). A missing or ambiguous slug is a USAGE error (64).
2. Verifies the task is extractable by requiring both `worktree.yml` and
   `pr.md`; missing either file aborts before extraction.
3. Runs a local secret-token preflight over any present `idea.md`,
   `brainstorm.md`, `plan.md`, `task.md`, and `pr.md`. The current local scan
   flags private keys, GitHub tokens, `sk-...` API keys, and AWS access keys;
   any finding aborts before a PR is opened.
4. Shells to hive-bench's `harness/extract.rb` (located via `HIVE_BENCH_PATH`,
   default `~/Dev/hive-bench`) to build the entry. The command derives the
   source repo from the project's `origin` remote and requires it to be a
   `github.com` remote.
5. Records the hive-bench checkout's original branch (or detached HEAD),
   resolves the remote default through `Hive::GitOps` (`origin/HEAD` with
   full-ref `origin/main` / `origin/master` fallbacks),
   creates `submit-<slug>` from that remote default, stages the generated
   entry, commits, pushes, and runs `gh pr create -R ivankuznetsov/hive-bench`.
   An ensure path restores the original branch/HEAD even when commit, push, or
   PR creation fails. Success records the exact submission ref and commit SHA;
   the entry locator is repository-relative so it remains meaningful after the
   original checkout has been restored and the entry is no longer present in
   the working tree.

## Notes

- hive depends on hive-bench only as a *producer* here; hive-bench never depends
  on hive. See [[commands]] for the full command list.
- `--json` emits a success document with `schema`, `slug`, `entry`, `pr_url`,
  `submission_ref`, and `commit_sha`; `entry` is relative to the hive-bench
  repository and the ref/SHA identify the checkout that contains it. The
  `schema: "hive-bench-submit"` contract is not currently registered in
  `Hive::Schemas::SCHEMA_VERSIONS`, and failures still use the normal stderr +
  exit-code path rather than a structured JSON error envelope. Injected legacy
  PR-opener seams that return only a URL retain the original fields but cannot
  supply ref/SHA metadata.
- The extractor and PR-opening subprocesses use argv/array-form `Open3` calls.
  The extractor `-I` flag and harness path are separate argv entries; the
  remaining Brakeman ignore for `gh pr create` is documented in [[testing]].
- Tests cover both injected seams and the default seam methods using a stub
  extractor script plus stub `git`/`gh` binaries. Real temporary repositories
  prove success and GitHub failure restore the original branch/HEAD, including
  exact detached-HEAD restoration, and that the reported locator resolves at
  the recorded submission SHA. Live hive-bench / GitHub submission evidence is
  tracked in [[gaps]].
