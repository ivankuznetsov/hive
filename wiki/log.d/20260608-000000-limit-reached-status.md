## [2026-06-08T00:00:00Z] agent/review — surface usage-limit as limits_reached, not generic failure

**Action:** Patrol/review tasks were landing in a red `reason=all_failed` (and agents in generic `exit_code=1`) when the underlying CLI had actually hit a usage/credit limit. Root cause: codex reports the limit as a structured `{"type":"error","message":"…you've hit your usage limit…"}` / `turn.failed` JSON stream event, which `MessageExtractor` does not surface as a final message, so the limit text never reached `Agent#handle_exit` (which only scanned `final_message`). Fix: `Agent#spawn_and_wait` now scans every raw stream line via `Hive::AgentLimit` and captures `result[:limit_text]`; `limit_error_message` prefers it. In `Stages::Review.run_reviewers`, per-reviewer error messages are collected and an all-failed phase whose failures are limit errors returns `:all_failed_limit`, landing a `REVIEW_ERROR reason=limits_reached message="all reviewers hit a usage/credit limit"` marker instead of `reason=all_failed`. Added agent unit tests (limit_text path + end-to-end structured-error capture) and a run_reviewers `:all_failed_limit` test.

**Refreshed pages:**
- [[testing]]
