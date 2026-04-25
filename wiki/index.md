---
title: Hive Wiki Index
type: index
created: 2026-04-25
updated: 2026-04-25
tags: [index]
---

# hive — Wiki Index

*Auto-generated. Do not edit manually.*

Folder-as-agent pipeline: a Ruby 3.4 / Thor CLI control plane that drives a six-stage filesystem state machine (`1-inbox` → `2-brainstorm` → `3-plan` → `4-execute` → `5-pr` → `6-done`) where stage agents run via `claude -p` and `mv` between directories is the only approval gesture.

**Pages**: 27 (excl. `index.md`/`log.md`) · **Date**: 2026-04-25

## Top level

- [[architecture]] — layer cake, process model, two filesystem trees, agent invocation contract, conventions.
- [[state-model]] — directory layout, marker grammar, state files, slug rules, configs, frontmatter, lock files, worktree pointer.
- [[cli]] — top-level CLI surface (entry point, command table, error conventions).
- [[dependencies]] — runtime gems, dev gems, external CLI deps, Ruby version, stdlib reliance.
- [[decisions]] — 13 ADRs extracted from the planning docs.
- [[active-areas]] — what's currently in flight and what's deferred.
- [[gaps]] — coverage table, open questions, patterns not yet documented.
- [[templates]] — ERB template catalogue and prompt-injection boundary policy.
- [[testing]] — minitest layout, fixtures, lint policy.

## Commands

- [[commands/init]] — bootstrap orphan branch, attach worktree, register globally.
- [[commands/new]] — capture an idea, derive a slug, scaffold `idea.md`.
- [[commands/run]] — dispatcher: lock → stage runner → commit → report (`--json` supported).
- [[commands/status]] — read-only table of every active task across registered projects (`--json` supported).
- [[commands/approve]] — agent-callable `mv <task> <next-stage>/` with marker validation, ambiguity resolution, and a hive/state commit per move.

## Stages

- [[stages/index]] — six-stage overview.
- [[stages/inbox]] — inert capture zone.
- [[stages/brainstorm]] — Q&A round-by-round.
- [[stages/plan]] — `/compound-engineering:ce-plan` driven plan.
- [[stages/execute]] — worktree + implementation + reviewer iteration.
- [[stages/pr]] — push branch + `gh pr create` (idempotent).
- [[stages/done]] — print cleanup commands, stamp COMPLETE.

## Modules

- [[modules/task]] — path parser & value object.
- [[modules/markers]] — locked HTML-comment marker protocol.
- [[modules/lock]] — per-task `.lock` + per-project `.commit-lock`.
- [[modules/worktree]] — git worktree wrapper + path-prefix validation.
- [[modules/git_ops]] — default-branch detection, hive-state bootstrap, `hive_commit`.
- [[modules/agent]] — `claude -p` subprocess wrapper with timeout/budget/atomic exit-status capture.
- [[modules/config]] — global + per-project YAML configs with deep-merge defaults.
- [[modules/stages]] — six-stage list + helpers; single source of truth for `DIRS` / `NAMES` / `SHORT_TO_FULL`.
