## 2026-07-10 — Document the babysitter dry-run prompt contract

**Action:** The PR-fixer dry-run prompt now lists the read-only `git` and `gh`
allowlist and explains that blocked commands return synthetic success. Agents
must treat the stderr skip marker as authoritative; the persistent skip log is
best-effort because unsafe or unavailable audit targets are rejected and
produce a warning instead of a write.

**Tests:** Prompt-rendering coverage pins the allowlist, skip marker, synthetic
success, best-effort audit write, and audit-write warning language.

**Wiki page updated:** `wiki/commands/babysit.md`.
