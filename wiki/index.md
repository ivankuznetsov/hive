---
title: Hive Wiki Index
type: index
created: 2026-04-25
updated: 2026-04-26
tags: [index]
---

# hive — Wiki Index

*Auto-generated. Do not edit manually.*

Folder-as-agent pipeline: a Ruby 3.4 / Thor CLI control plane that drives a seven-stage filesystem state machine (`1-inbox` → `2-brainstorm` → `3-plan` → `4-execute` → `5-review` → `6-pr` → `7-done`) where stage agents run via configurable AgentProfile CLIs (`claude` default, `codex`, `pi`) and `mv` between directories is the only approval gesture.

**Pages**: 36 (excl. `index.md`/`log.md`) · **Date**: 2026-04-27

## Top level

- [[architecture]] — layer cake, process model, two filesystem trees, agent invocation contract, conventions.
- [[state-model]] — directory layout, marker grammar, state files, slug rules, configs, frontmatter, lock files, worktree pointer.
- [[cli]] — top-level CLI surface (entry point, command table, error conventions).
- [[dependencies]] — runtime gems, dev gems, external CLI deps, Ruby version, stdlib reliance.
- [[decisions]] — 21 ADRs (013 + 014–021 added 2026-04-26 alongside 5-review).
- [[active-areas]] — what's currently in flight and what's deferred.
- [[gaps]] — coverage table, open questions, patterns not yet documented.
- [[templates]] — ERB template catalogue and prompt-injection boundary policy.
- [[testing]] — minitest layout, fixtures, lint policy.

## Commands

- [[commands/init]] — bootstrap orphan branch, attach worktree, register globally.
- [[commands/new]] — capture an idea, derive a slug, scaffold `idea.md`.
- [[commands/run]] — dispatcher: lock → stage runner → commit → report (`--json` supported).
- [[commands/status]] — read-only table of every active task across registered projects (`--json` supported).
- [[commands/tui]] — live, keystroke-driven curses dashboard over `hive status` (human-only; no JSON).
- [[commands/approve]] — agent-callable `mv <task> <next-stage>/` with marker validation, ambiguity resolution, and a hive/state commit per move.
- [[commands/findings]] — `hive findings` / `accept-finding` / `reject-finding`: list and toggle GFM-checkbox findings in `reviews/ce-review-NN.md`.
- [[commands/stage_action]] — `hive brainstorm` / `plan` / `develop` / `pr` / `archive` workflow verbs (promote-or-run).
- [[commands/markers]] — `hive markers clear FOLDER --name <NAME>` removes a recovery marker (`REVIEW_STALE` etc.) from `task.md` so an agent can recover from `REVIEW_*_STALE` / `REVIEW_ERROR` without hand-editing.
- `hive metrics rollback-rate [--days N] [--project NAME] [--json]` — fraction of fix-agent commits later reverted, broken down by triage bias / fix phase. See [[cli]] and [[stages/review]].

## Stages

- [[stages/index]] — seven-stage overview.
- [[stages/inbox]] — inert capture zone.
- [[stages/brainstorm]] — Q&A round-by-round.
- [[stages/plan]] — `/compound-engineering:ce-plan` driven plan.
- [[stages/execute]] — worktree + implementation (impl-only since ADR-014).
- [[stages/review]] — autonomous review loop: CI-fix → reviewers → triage → fix → guardrail → browser-test.
- [[stages/pr]] — push branch + `gh pr create` (idempotent).
- [[stages/done]] — print cleanup commands, stamp COMPLETE.

## Modules

- [[modules/task]] — path parser & value object.
- [[modules/markers]] — locked HTML-comment marker protocol.
- [[modules/lock]] — per-task `.lock` + per-project `.commit-lock`.
- [[modules/worktree]] — git worktree wrapper + path-prefix validation.
- [[modules/git_ops]] — default-branch detection, hive-state bootstrap, `hive_commit`.
- [[modules/agent]] — agent CLI subprocess wrapper with timeout/budget/atomic exit-status capture.
- [[modules/agent_profile]] — per-CLI invocation contract value-object + registry (claude / codex / pi).
- [[modules/config]] — global + per-project YAML configs with deep-merge defaults.
- [[modules/stages]] — seven-stage list + helpers; single source of truth for `DIRS` / `NAMES` / `SHORT_TO_FULL`.
- [[modules/findings]] — parser + writer for `reviews/ce-review-NN.md`; CRLF-safe round-trip toggle.
- [[modules/task_resolver]] — slug-or-folder TARGET resolution shared by every agent-callable command.
- [[modules/task_action]] — `(task, marker) → action key/label/command` classifier driving `hive status` and `next_action` emission.
- [[modules/workflows]] — verb→stage SSOT (brainstorm/plan/develop/pr/archive) consumed by every workflow command.
- [[modules/reviewers]] — Phase 2 reviewer adapter layer (dispatch, Context, Result, Agent, SyntheticTask).
- [[modules/metrics]] — `hive metrics rollback-rate` library (trailer parsing, revert detection).
- [[modules/secret_patterns]] — shared regex set for credential/secret detection.
- [[modules/protected_files]] — SHA-256 snapshot/diff helper for orchestrator-owned files.
