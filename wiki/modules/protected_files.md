---
title: Hive::ProtectedFiles
type: module
source: lib/hive/protected_files.rb
created: 2026-04-26
updated: 2026-07-24
tags: [security, sha256, integrity, orchestrator]
---

**TLDR**: SHA-256 snapshot/diff plus in-memory capture/atomic-restore helper
for orchestrator-owned files. Execute, open-PR, review, finalize, and managed
worktree stages restore changed controller bytes immediately after an agent
spawn, then record structured tamper errors. A retry is eligible only when the
marker proves `restored=true`; failed reconstruction remains safety-blocked.
References ADR-013.

## API

```ruby
Hive::ProtectedFiles::ORCHESTRATOR_OWNED = %w[
  plan.md worktree.yml handoff.yml task.md task-journal.jsonl task-projection.json
].freeze

capture = Hive::ProtectedFiles.capture(root)
Hive::ProtectedFiles.snapshot(root, names = ORCHESTRATOR_OWNED)
# → { "plan.md" => "<sha256>", "worktree.yml" => nil, "task.md" => "<sha256>" }

Hive::ProtectedFiles.diff(before, after)
# → ["plan.md", …]  # names that changed (or were added/removed)

Hive::ProtectedFiles.restore_safely(root, capture, changed_names)
# → [true, nil] or [false, "<class>: <reason>"]
```

Missing files are recorded as `nil` so a deletion is detected as a difference.
Regular files retain the content SHA-256 shape. Non-regular entries record a
type-bearing signature, so replacing a protected regular file with a symlink to
identical bytes is still detected.

`capture` keeps original bytes and mode in controller memory. `restore` writes
regular files through `Hive::AtomicFile`, removes files that were originally
absent (including forged completion sentinels), and verifies the final
fingerprint. It never recursively deletes an agent-created directory.
Originally non-regular paths are intentionally unreconstructable: if changed,
restoration fails closed and the tamper marker carries `restored=false`.
`capture_paths` / `restore_paths_safely` provide the same contract for named
Git control files outside the task folder.

## Used by

- **`Stages::Execute.run!`** — wraps the implementation spawn (ADR-013).
  Tampering yields `ERROR reason=implementer_tampered` with restoration status.
- **`Stages::OpenPr.run!` and `Stages::Finalize.run!`** — protect task control
  files around PR-authoring agents before any retry can trust them.
- **`Stages::Review.run!#spawn_fix_agent`** — wraps Phase 4. Includes the per-pass `escalations-NN.md`, reviewer infra/error sentinels, fix-success/guardrail sentinels, and `reviews/suppressed.md` so a fix agent rewriting them (e.g., flipping `[ ]` → `[x]` to short-circuit human review, or clearing no-fix suppressions) trips `REVIEW_ERROR phase=fix reason=fix_tampered`.
- **`Stages::Review::Triage.run!`** — wraps the triage spawn (`TRIAGE_PROTECTED_FILES = ORCHESTRATOR_OWNED + ["reviews/suppressed.md"]`). Triage may edit reviewer files in place but must NOT touch plan.md / worktree.yml / task.md / the suppression list (clearing no-fix suppressions there would defeat convergence — U3/A4). The triage-local addition leaves the shared `ORCHESTRATOR_OWNED` constant untouched; timing is safe because `strip_suppressed!` writes the list before the snapshot and `seed_from_triage!` after it. Tampering yields `REVIEW_ERROR phase=triage reason=triage_tampered`.
- **`Stages::Review::CiFix.run!`** — wraps each CI-fix attempt. Tampering yields `Result.new(status: :error, error_message: "ci fix agent modified protected files: …")` which the runner translates to `REVIEW_ERROR phase=ci`.
- **`Stages::AgentWorktree.run!`** — wraps the single draft-PR repair spawn.
  Its stage-local set extends `ORCHESTRATOR_OWNED` with `meta.yml` and
  `pr.md`; `fix-report.md` is the only allowed task-folder
  output. The extension is local because open-PR/finalize agents legitimately
  own `pr.md` in the coding workflow. Its task files and local/global Git
  control paths are restored before the controller emits its private failure.

## Why these files

- `plan.md` — the implementation contract. A fix agent that rewrites the plan is rewriting its own job description.
- `worktree.yml` — the runner's pointer into the project's worktree. Mutating it would re-direct subsequent spawns.
- `handoff.yml` — the controller's managed publication phase receipt.
- `task.md` — carries the marker. The orchestrator owns every terminal marker; a sub-agent writing one would short-circuit the state machine.
- `task-journal.jsonl` and `task-projection.json` — durable attempt/event state
  used to reconcile execution ownership.

Consumers add stage-specific controller files where ownership differs. The
draft-PR worktree stage adds `meta.yml` (identity/provenance/base) and `pr.md`
(controller-authored PR identity) without changing the coding
open-PR/finalize ownership model.

Reviewer-owned files (`reviews/<reviewer>-NN.md`) are NOT in this set: triage's job is to edit them in place. The escalations file and suppression list are added to the snapshot at fix-time so the orchestrator/triage own them but the fix agent cannot touch them.

## Tests

- Coverage is co-located with the consumers: `test/unit/protected_files_test.rb`
  pins the canonical set and symlink-aware diff; `test/unit/stages/agent_test.rb`
  covers draft-PR agent tampering; review/execute integration tests cover their
  stage-specific enforcement.

## Backlinks

- [[stages/execute]] · [[stages/review]]
- [[decisions]] (ADR-013)
