# 2026-10-14 — Claude launches only as headless `claude -p`

- Anthropic confirmed that `claude -p` is permitted under a Claude
  subscription, so ADR-030's tmux launch mode (kept only to bill the
  subscription) is obsolete. Every Claude launch from a stage, reviewer, or
  helper is now headless; ADR-030 is superseded by ADR-053 in [[decisions]].
- Deleted: `Hive::TmuxRunner`, the interactive wrapper and Stop-hook
  scripts, `Hive::StopHookInstaller`, `Hive::ClaudeCompletionFallback`, the
  `:Interactive` facet, and every tmux internal of `Hive::ClaudeLauncher`.
  The new `Hive::AgentSupport::Claude::Launch` facet carries the tool
  scopes, `DENIED_TOOLS`, MCP flags, and profile guard;
  `supports?(profile, :Launch)` is the "is this Claude" check.
- `Stages::Base.spawn_agent` denies `AskUserQuestion` on every Claude launch
  without a workflow `runtime_policy`. Claude reviewers run as independent
  headless reviewers (no shared tmux session, so slightly less prompt-cache
  reuse within a pass). The review-fix completion fallback is gone;
  `spawn_claude_with_tmux_marker!` is now `spawn_claude_with_failure_marker!`
  and still writes `claude_launch_failed`. Yolo Claude launches keep the
  stage's default `--allowedTools`.
- `ClaudeLauncher` repairs a tmux-era Stop-hook `.claude/settings.json` stub
  or its `.hive-pre-install` backup before launching. Legacy reasons
  (`tmux_session_terminated`, `reviewer_tmux_session_terminated`,
  `fix_claude_stop_hook`) and the `claude_completion_fallback` event type
  stay read-side only.
- Config: `claude.mode` is removed; a leftover value loads and is ignored,
  and `hive doctor` reports it as a `claude/config` warning. Doctor drops the
  tmux dependency row and reports exported `ANTHROPIC_API_KEY` /
  `CLAUDE_API_KEY` as a `claude/auth` warning. `hive setup` no longer
  requires tmux. `hive init` no longer asks for a launch mode, and
  `hive init --json` moves to `hive-init.v3` without `claude_mode`.
- tmux remains only for the TUI e2e harness and the Docker image's
  `hive tui` session ([[dependencies]]). Gaps 14, 17, 17a, 34, the tmux
  large-prompt settle item, and the xbookmark triage `tmux has-session`
  question are closed in [[gaps]].
