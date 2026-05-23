# ADR-030: Global Claude Launch Mode

**Status:** Accepted
**Date:** 2026-05-22

## Context

Hive first added an interactive tmux runtime for `2-brainstorm` only. That solved the billing/auth problem for brainstorm, but every other Claude-backed stage still used the headless `claude -p` path. The result was a mixed launch contract: one stage could use the operator's logged-in Claude session while plan, execute, open-pr, review sub-spawns, artifacts, and finalize could not.

## Decision

Add one project-global setting:

```yaml
claude:
  mode: tmux   # tmux | headless
```

`tmux` is the default for new projects and for existing projects that omit the key. When a stage's resolved `AgentProfile` is Claude, the stage calls `Hive::Stages::Base.spawn_claude!`, which delegates to `Hive::ClaudeLauncher` and honors `claude.mode`. Non-Claude profiles are unaffected and keep the normal headless `spawn_agent` path.

`brainstorm.runtime` is deprecated. It remains readable for one release as a brainstorm-only fallback when `claude.mode` is absent, and `hive doctor` warns operators to migrate.

For 6-review, Claude reviewers run sequentially inside one shared tmux session per pass under `claude.mode: tmux`. Non-Claude reviewers remain headless. Parallel reviewer panes and per-stage Claude-mode overrides are intentionally out of scope.

## Consequences

- `tmux` is now a runtime dependency whenever `claude.mode: tmux`; missing or too-old tmux is a hard failure, not a silent fallback.
- Switching modes is a config edit plus stage restart.
- Future Claude-backed stages inherit the launch setting by using `spawn_claude!`.
- **Daemon / service hosts MUST set `claude.mode: headless`.** The default `tmux` mode requires an attached terminal for trust-prompt and ready-prompt detection; daemon hosts running without a TTY would hard-fail on every Claude-backed task. Auto-fallback to headless is explicitly out of scope (R10) — the operator opts in via config so the launch contract stays a single, inspectable choice.
- **Legacy env-var prefix `HIVE_BRAINSTORM_TMUX_*` deprecation.** Every tmux tuneable now reads `HIVE_CLAUDE_TMUX_<KEY>` first and falls back to `HIVE_BRAINSTORM_TMUX_<KEY>`. The legacy prefix remains readable for one release and is dropped in the next minor release after the `claude.mode` rollout — service units, CI envs, and `direnv` files that set the legacy form must migrate.
