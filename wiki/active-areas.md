---
title: Active Areas
type: active-areas
source: working tree (no git history yet)
created: 2026-04-25
updated: 2026-04-25
tags: [roadmap, status]
---

**TLDR**: Greenfield repo. No git commits yet — `git log` is empty as of this writing. Active surface is the entire MVP, currently at "implemented + tested locally, not yet committed".

## Status

`git status` (2026-04-25) shows the entire working tree as untracked. The first commit hasn't been authored. So "active areas based on the last 6 months of git activity" is degenerate — *everything* is active.

## What exists

| Area | Files | Status |
|------|-------|--------|
| CLI surface | `bin/hive`, `lib/hive/cli.rb`, `lib/hive/commands/{init,new,run,status}.rb` | Implemented + integration-tested |
| Stage runners | `lib/hive/stages/{base,inbox,brainstorm,plan,execute,pr,done}.rb` | Implemented + integration-tested |
| Core modules | `lib/hive/{task,markers,lock,worktree,git_ops,agent,config}.rb` | Implemented + unit-tested |
| Templates | `templates/*.erb` (8 files) | Drafted |
| Tests | `test/unit/*.rb` (7 files), `test/integration/*.rb` (10 files) | Local; CI not yet wired |
| Docs | `docs/brainstorms/hive-pipeline-requirements.md`, `docs/plans/2026-04-24-001-feat-hive-phase-1-mvp-plan.md`, `README.md` | Authored |

## Phase 1 deferred work (per `docs/plans/...mvp-plan.md` "Deferred to Follow-Up Work")

- Additional reviewers in `4-execute` (Codex local, pr-review-toolkit, rubocop-as-reviewer).
- Second pilot project (candidate: `seyarabata-new` or `todero`) and cross-project `hive status`.
- Atomic rollback via snapshot tags on `hive/state` per stage transition (Phase 3).
- `hive reinit <new-path>` for migrating registered project paths.
- `--stage` / `--slug` flags on `hive new` if ergonomics warrants it.

## Phase 2/3 work (also deferred)

- Dispatcher daemon at `~/Dev/hive/daemon.rb` with polling + fswatch.
- Telegram bot bidirectional adapter.
- Observability probes track (`<project>/.hive-state/reports/`).
- QMD export of `6-done/` task artefacts to per-project learning collections.
- `gh api` PR-comment ingestion into `reviews/pr-comments-NN.md`.

## What's NOT implemented yet (per plan)

- `--force` flag on `hive run` for `EXECUTE_STALE` recovery — current MVP requires manual marker removal + frontmatter edit.
- macOS fallback for PID-reuse detection (currently Linux `/proc/<pid>/stat` only).
- Pre-commit hook integration on `hive/state` commits — flagged as a known caveat in the plan's Risks table.

## Backlinks

- [[gaps]]
- [[architecture]]
- [[decisions]]
