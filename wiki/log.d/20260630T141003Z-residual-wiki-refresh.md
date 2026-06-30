---
title: Residual wiki refresh for daemon auto-retry and ad-hoc review
date: 2026-06-30
---

Refreshed LLM wiki coverage for branch `make-the-hive-daemon-automatically-260629-223d` after its residual 6-review commit touched command/module/state/test wiki pages, gaps, index metadata, and changelog fragments.

Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, and existing branch-specific log fragments first. `qmd search "make-the-hive-daemon-automatically recoverable auto retry adhoc review"` returned no indexed hits, so verification used direct wiki/source search plus the configured main-wiki path.

Verified the committed wiki diff and source/test evidence with `git show make-the-hive-daemon-automatically-260629-223d:<path>`: `Hive::Daemon::RecoverableErrorHealer` handles only the fixed dependency-outage allowlist, emits task-local `auto_retry` / `auto_retry_skipped` events while daemon logs keep `auto_retry_exhausted` / `auto_retry_failed`, observes pre-clear mtimes, and requeues `3-plan` after successful clears; `Hive::Commands::AdhocReview` creates or reuses synthetic `6-review/adhoc-review-pr-N` tasks through `Hive::Gh.pr_metadata`, `Hive::Pr.identifier_to_number`, and `Hive::Worktree.materialize_pr`, with ad-hoc fixes disabled by default through `review.adhoc.fix: false`.

Updated [[state-model]] to include the recoverable dependency-outage healer alongside existing terminal-`ERROR` auto-clear semantics, and carried forward [[gaps]] uncertainty for the missing live-daemon Codex/Claude retry smoke and missing live `hive review --pr` smoke. No page was created, so [[index]] page coverage did not change. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.
