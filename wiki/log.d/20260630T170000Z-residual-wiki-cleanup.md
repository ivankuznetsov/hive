---
title: Residual wiki cleanup for daemon auto-retry and ad-hoc review
date: 2026-06-30
---

Refreshed main-checkout LLM wiki coverage for `make-the-hive-daemon-automatically-260629-223d` after its residual 6-review commit changed wiki pages and changelog fragments.

Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, and the configured main-wiki path first. `qmd search "make hive daemon automatically auto retry recoverable ad hoc review"` returned no indexed hits, so verification used direct wiki/source search and the branch diff.

Inspected the committed diff plus current source/tests: `Hive::Daemon::RecoverableErrorHealer` still emits task-local `auto_retry` / `auto_retry_skipped` while daemon logs accept `auto_retry`, `auto_retry_skipped`, `auto_retry_exhausted`, and `auto_retry_failed`; `daemon.auto_retry.enabled` remains the kill switch; and `hive review --pr` is implemented through `Hive::Commands::AdhocReview`, `Hive::Gh.pr_metadata`, `Hive::Pr.identifier_to_number`, and `Hive::Worktree.materialize_pr`.

Normalized branch-only wording in [[cli]], [[commands]], [[commands/stage_action]], [[modules/config]], [[modules/gh]], [[modules/pr]], [[modules/worktree]], [[state-model]], [[stages/review]], and [[testing]]. Carried forward [[gaps]] uncertainty for the missing live-daemon recoverable-error smoke and missing live `hive review --pr` smoke. No page was created, so [[index]] page coverage did not change. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.
