---
title: Review-fix wiki cleanup for daemon auto-retry and ad-hoc review
date: 2026-06-30
---

Refreshed main-checkout LLM wiki coverage for branch `make-the-hive-daemon-automatically-260629-223d` after its review-fix commit changed wiki pages and changelog fragments.

Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, and the configured main-wiki path first. `qmd search "make-the-hive-daemon-automatically recoverable error healer adhoc review"` returned no hits, and the configured main-wiki path had no branch-specific context.

Inspected the committed wiki diff plus current branch source/tests: `Hive::Daemon::RecoverableErrorHealer` still provides the fixed v1 dependency-outage auto-retry path with task-local `auto_retry` / `auto_retry_skipped` and broader daemon-log audit names, and `Hive::Commands::AdhocReview` still creates/reuses `6-review/adhoc-review-pr-N` tasks through PR metadata, PR-head materialization, and normal `6-review` dispatch. The same source check found no `lib/hive/commands/setup.rb` and no daemon binary-drift status payload in the branch.

Removed stale setup-command and daemon binary-drift coverage from [[index]], [[cli]], [[commands]], [[commands/daemon]], [[commands/web]], [[testing]], and [[gaps]], and deleted the stale [[commands/setup]] page from the main wiki. Carried forward [[gaps]] uncertainty for the missing live-daemon recoverable-error smoke and missing live `hive review --pr` smoke. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.
