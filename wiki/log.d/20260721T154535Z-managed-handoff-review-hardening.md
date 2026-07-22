# 2026-07-21 — review-harden managed repair handoff

**Action:** Closed the managed worktree/draft-PR review findings. The descriptor
now admits only the exact terminal `workspace: worktree` + `handoff: draft_pr`
pair with task-root `fix-report.md`; managed runs skip auto-rebase, surface
early explicit worktree pointers, and project every provider/validation failure
to a controller-owned error marker. Terminal replay retries no-fix cleanup and
quarantine redaction, preserves exact report bytes, and returns a durable
recovery action.

**Security:** Added `Hive::ManagedGit` for every post-agent Git validation,
scan, cleanup, observation, and push. It uses an allowlisted command surface,
reduced environment, null global/system config, disabled hooks/fsmonitor and
external diff/textconv, closed protocols, and explicit GitHub credential
handling. Agent-spawn integrity snapshots now include Git control/config paths,
and structured provider message payloads are omitted from durable logs so
credentials split across JSON events cannot be reconstructed.

**Coverage:** Added focused regression coverage for Git helper suppression,
Git/task control tampering, runtime failure markers, shared branch validation,
closed descriptor shapes, managed rebase skipping, low-stage pointer visibility,
ambiguous mutation retry guards, raw report-byte recovery, cleanup/redaction
resume, unfamiliar post-push OIDs, trusted prompt context, and structured-log
redaction. Updated [[cli]], [[commands/run]], [[commands/status]], [[modules/workflows]],
[[modules/worktree]], [[modules/gh]], [[modules/agent]], [[stages/agent]],
[[state-model]], [[testing]], and [[gaps]]. The configured main wiki path was absent; no compiled
`wiki/log.md` edit or QMD index mutation was performed.
