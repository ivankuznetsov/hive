---
ts: 2026-06-08T19:15:21Z
slug: babysitter-auto-rebase-behind-prs
tags: [babysitter, github, decision]
---

## Babysitter: auto-rebase green-but-BEHIND PRs to keep them mergeable

**Problem.** Strict branch protection on `main` requires a PR branch to be up-to-date with the base before it can merge. When `main` advances, an open PR goes `mergeStateStatus=BEHIND` — but it is still `mergeable=MERGEABLE` and green, so `PrFixer#already_green?` short-circuited to a `noop`/`already-green` event. The PR stayed BEHIND and un-mergeable forever; the babysitter did nothing about it.

**Change.** When a PR is green, `PrFixer` now routes through `handle_green`:

- **green + `BEHIND` + auto-rebase enabled** → materialize the PR worktree, `GhOps.rebase_onto_base` (`git fetch origin <base>` then `git rebase origin/<base>`), then on a clean rebase `GhOps.force_push_with_lease`. Emits `rebase`/`success`; returns `:rebased` (tallied as `fixed`). A rebase that hits conflicts is `git rebase --abort`ed and left for a human — no force-push, no fix agent, no label — emits `rebase`/`conflict`; returns `:rebase_conflict` (tallied as `needs_human`); re-evaluated cheaply next tick. A fetch/other failure or a failed push emits `rebase`/`failure` and returns `:failure`. Dry-run emits `rebase`/`dry_run`, returns `:dry_run`, and touches no git.
- **green + not `BEHIND`** → unchanged `noop`/`already-green`.

`behind?` reads `status["mergeStateStatus"]` from the rollup, falling back to the PR object's `mergeStateStatus`. Auto-rebase is gated on `babysitter.auto_rebase` with **nil treated as true** — only an explicit `false` opts out (mirrors the "do not silently flip legacy projects" convention).

**New rebase helper.** `GhOps.rebase_onto_base(worktree, base_ref, cfg:, dry_run:)` returns a `RebaseResult` Struct (`status` ∈ `:success`/`:conflict`/`:failure`, plus `stdout`/`stderr` and `success?`/`conflict?` predicates), built via `Hive::Gh.capture3` in the same style as `force_push_with_lease`. Conflicts run a best-effort `git rebase --abort`.

**Events.** Added action `rebase` and outcome `conflict` to the closed allowlists in `events.rb`; `emit` still raises on anything outside them.

**Config.** Added `babysitter.auto_rebase => true` to `Config::DEFAULTS` and to `templates/project_config.yml.erb`; `validate_babysitter!` now boolean-validates `auto_rebase` alongside `enabled`/`dry_run`.

**Tally.** `ProjectTick` maps `:rebased` → `fixed` and `:rebase_conflict` → `needs_human`.

**Tests.** `gh_ops_test` (rebase success / conflict-abort / fetch-failure / dry-run), `pr_fixer_test` (green+BEHIND → rebased + push, conflict → no push + no agent, push-failure → failure, rebase-error → failure, `auto_rebase:false` → noop, green+CLEAN → noop, dry-run → rebase/dry_run + no git, plus the `@pr` mergeStateStatus fallback), `events_test` (rebase/conflict accepted; unknown still raises), `project_tick_test` (`:rebased`/`:rebase_conflict` tally), `config_test` (auto_rebase default true + round-trip + non-boolean rejected). Full `rake test` green: 4975 runs, 0 failures/0 errors, 100% line-coverage gate satisfied. rubocop clean on changed files.

**Refreshed pages:**
- [[modules/babysitter]]
- [[commands/babysit]]
