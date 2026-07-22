---
title: Hive::ProtectedFiles
type: module
source: lib/hive/protected_files.rb
created: 2026-04-26
updated: 2026-07-21
tags: [security, sha256, integrity, orchestrator]
---

**TLDR**: SHA-256 snapshot/diff helper for orchestrator-owned files. Multiple stages (4-execute, 6-review's runner / triage / ci-fix) all need the same primitive: snapshot a small set of files before spawning a sub-agent, snapshot again after, surface the names that differ. Tampering attempts land structured error markers (`REVIEW_ERROR phase=X reason=*_tampered`). One Array constant, two functions. Centralises the "what counts as orchestrator-owned" answer so a future addition to the protected set lands in one place. References ADR-013.

## API

```ruby
Hive::ProtectedFiles::ORCHESTRATOR_OWNED = %w[
  plan.md worktree.yml task.md task-journal.jsonl task-projection.json
].freeze

Hive::ProtectedFiles.snapshot(root, names = ORCHESTRATOR_OWNED)
# → { "plan.md" => "<sha256>", "worktree.yml" => nil, "task.md" => "<sha256>" }

Hive::ProtectedFiles.diff(before, after)
# → ["plan.md", …]  # names that changed (or were added/removed)
```

Missing files are recorded as `nil` so a deletion is detected as a difference.
Regular files retain the content SHA-256 shape. Non-regular entries record a
type-bearing signature, so replacing a protected regular file with a symlink to
identical bytes is still detected.

## Used by

- **`Stages::Execute.run!`** — wraps the implementation spawn (ADR-013). Tampering yields `EXECUTE_ERROR phase=implementation reason=tampered`.
- **`Stages::Review.run!#spawn_fix_agent`** — wraps Phase 4. Includes the per-pass `escalations-NN.md`, reviewer infra/error sentinels, fix-success/guardrail sentinels, and `reviews/suppressed.md` so a fix agent rewriting them (e.g., flipping `[ ]` → `[x]` to short-circuit human review, or clearing no-fix suppressions) trips `REVIEW_ERROR phase=fix reason=fix_tampered`.
- **`Stages::Review::Triage.run!`** — wraps the triage spawn (`TRIAGE_PROTECTED_FILES = ORCHESTRATOR_OWNED + ["reviews/suppressed.md"]`). Triage may edit reviewer files in place but must NOT touch plan.md / worktree.yml / task.md / the suppression list (clearing no-fix suppressions there would defeat convergence — U3/A4). The triage-local addition leaves the shared `ORCHESTRATOR_OWNED` constant untouched; timing is safe because `strip_suppressed!` writes the list before the snapshot and `seed_from_triage!` after it. Tampering yields `REVIEW_ERROR phase=triage reason=triage_tampered`.
- **`Stages::Review::CiFix.run!`** — wraps each CI-fix attempt. Tampering yields `Result.new(status: :error, error_message: "ci fix agent modified protected files: …")` which the runner translates to `REVIEW_ERROR phase=ci`.
- **`Stages::AgentWorktree.run!`** — wraps the single draft-PR repair spawn.
  Its stage-local set extends `ORCHESTRATOR_OWNED` with `meta.yml`,
  `handoff.yml`, and `pr.md`; `fix-report.md` is the only allowed task-folder
  output. The extension is local because open-PR/finalize agents legitimately
  own `pr.md` in the coding workflow.

## Why these files

- `plan.md` — the implementation contract. A fix agent that rewrites the plan is rewriting its own job description.
- `worktree.yml` — the runner's pointer into the project's worktree. Mutating it would re-direct subsequent spawns.
- `task.md` — carries the marker. The orchestrator owns every terminal marker; a sub-agent writing one would short-circuit the state machine.
- `task-journal.jsonl` and `task-projection.json` — durable attempt/event state
  used to reconcile execution ownership.

Consumers add stage-specific controller files where ownership differs. The
draft-PR worktree stage adds `meta.yml` (identity/provenance/base),
`handoff.yml` (controller phase receipt), and `pr.md` (controller-authored PR
identity) without changing the coding open-PR/finalize ownership model.

Reviewer-owned files (`reviews/<reviewer>-NN.md`) are NOT in this set: triage's job is to edit them in place. The escalations file and suppression list are added to the snapshot at fix-time so the orchestrator/triage own them but the fix agent cannot touch them.

## Tests

- Coverage is co-located with the consumers: `test/unit/protected_files_test.rb`
  pins the canonical set and symlink-aware diff; `test/unit/stages/agent_test.rb`
  covers draft-PR agent tampering; review/execute integration tests cover their
  stage-specific enforcement.

## Backlinks

- [[stages/execute]] · [[stages/review]]
- [[decisions]] (ADR-013)
