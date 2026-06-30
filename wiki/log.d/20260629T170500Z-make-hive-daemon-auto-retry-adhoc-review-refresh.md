---
title: Recoverable healer and ad-hoc review wiki refresh
date: 2026-06-29
---

Refreshed LLM wiki coverage for branch `make-the-hive-daemon-automatically-260629-223d` after its residual docs commit touched command/module/state/test wiki pages and changelog fragments.

Verified the committed wiki diff against committed source and tests using `git show <branch-change>:<path>`: `Hive::Daemon::RecoverableErrorHealer` keeps task-local events to `auto_retry` / `auto_retry_skipped` while daemon logs also accept `auto_retry_exhausted` / `auto_retry_failed`; `daemon.auto_retry.enabled` is the global kill switch; and the branch also adds the `hive review --pr` ad-hoc PR review path through `Hive::Commands::AdhocReview`, `Hive::Gh.pr_metadata`, `Hive::Pr.identifier_to_number`, and `Hive::Worktree.materialize_pr`.

Updated [[cli]], [[commands]], [[commands/daemon]], [[commands/stage_action]], [[modules/config]], [[modules/gh]], [[modules/pr]], [[modules/worktree]], [[stages/review]], [[testing]], and [[gaps]]. No page was created, so [[index]] page coverage did not change. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.
