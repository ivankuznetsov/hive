## [2026-06-30T08:43:46Z] modules/agent — claude tmux Stop-hook completion fallback

**Action:** Documented the tmux Stop-hook completion fallback and the 2026-06-30 root-cause finding. `ClaudeLauncher` now attaches additive `completion_evidence` to missing-Stop-hook `:exit_code_only` timeouts, and [[stages/review]] review-fix can suppress `REVIEW_ERROR phase=fix reason=fix_failed` only when both launcher evidence and review artifacts/commit-or-no-change facts prove completion.

**Why:** Interactive Claude REPL runs can finish a turn without writing the expected `.done` / `result.json` Stop-hook sentinels. The leading hypothesis is absent or late Stop-hook delivery in interactive tmux mode; path drift and script write ordering are guarded by `StopHookInstaller` contract tests.

**References:** [[modules/agent]], [[stages/review]]
