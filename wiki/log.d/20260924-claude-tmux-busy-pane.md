# 2026-09-24 — Claude tmux mode: busy panes and per-stage model pins

- `claude_ready_prompt?` now rejects a pane whose footer shows `esc to interrupt`.
  Claude Code keeps the idle-looking caret and footer painted while a turn runs,
  so the completion loop read a working pane as idle, reported "claude stop hook
  did not signal completion", and killed execute attempts about ten seconds in.
- `Stages::Base.spawn_claude!` and `ClaudeLauncher.launch!` accept `model:` and
  `effort:`. Stages splat per-stage model routing into these calls, so a
  per-stage `model`/`effort` under `claude.mode: tmux` previously raised
  `ArgumentError: unknown keywords: :model, :effort`. Per-stage values now
  override the project-global `claude.model`/`claude.effort` pins.
