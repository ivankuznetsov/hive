# 2026-08-30 — Planner revision transient recovery

Planner revisions now keep provider failures recoverable without raising the
global attempt limit. Each invocation still has the configured bounded attempt
series, but exhaustion persists a deterministic cooled recovery reset and the
daemon opens later series until the original planner route succeeds. Exact
transient planner blocks left by older builds are runnable after upgrade;
invalid or terminal planner results remain blocked. The independent cap on
successful verification-driven revision rounds is unchanged.
