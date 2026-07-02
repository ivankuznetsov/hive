---
timestamp: 2026-07-01T09:32:32Z
title: HEAD review-fix Stop-hook recovery coverage refresh
---

Refreshed wiki coverage after branch HEAD narrowed `docs/notes/claude-tmux-launch-mode.md` recovery guidance for Claude/tmux review-fix Stop-hook failures. Inspected the committed diff, the committed note via `git show HEAD:docs/notes/claude-tmux-launch-mode.md`, `docs/recipes.md`, `lib/hive/claude_launcher.rb`, `lib/hive/stages/review.rb`, `lib/hive/daemon/stale_agent_healer.rb`, `lib/hive/events.rb`, `test/integration/run_review_test.rb`, and `test/unit/daemon/stale_agent_healer_test.rb`. Updated [[stages/review]], [[state-model]], and [[testing]] so the wiki documents the actual fallback predicate: session-alive launcher evidence plus review facts, artifacts, zero unresolved escalations, readable worktree, and commit / dirty-worktree / whole-pass `RESOLVED/NO-FIX` evidence before `claude_completion_fallback` can suppress the known stop-hook timeout. Added [[gaps]] uncertainty because this is still source/integration-pinned; no checked-in live Claude/tmux replay artifact was found. Did not edit compiled [[log]] and did not run `qmd update` or `qmd embed`.
