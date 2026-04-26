---
title: Hive::ProtectedFiles
type: module
source: lib/hive/protected_files.rb
created: 2026-04-26
updated: 2026-04-26
tags: [security, sha256, integrity, orchestrator]
---

**TLDR**: SHA-256 snapshot/diff helper for orchestrator-owned files. Multiple stages (4-execute, 5-review's runner / triage / ci-fix) all need the same primitive: snapshot a small set of files before spawning a sub-agent, snapshot again after, surface the names that differ. Tampering attempts land structured error markers (`REVIEW_ERROR phase=X reason=*_tampered`). One Array constant, two functions. Centralises the "what counts as orchestrator-owned" answer so a future addition to the protected set lands in one place. References ADR-013.

## API

```ruby
Hive::ProtectedFiles::ORCHESTRATOR_OWNED = %w[plan.md worktree.yml task.md].freeze

Hive::ProtectedFiles.snapshot(root, names = ORCHESTRATOR_OWNED)
# → { "plan.md" => "<sha256>", "worktree.yml" => nil, "task.md" => "<sha256>" }

Hive::ProtectedFiles.diff(before, after)
# → ["plan.md", …]  # names that changed (or were added/removed)
```

Missing files are recorded as `nil` so a deletion is detected as a difference (otherwise a missing-vs-missing pair would compare equal).

## Used by

- **`Stages::Execute.run!`** — wraps the implementation spawn (ADR-013). Tampering yields `EXECUTE_ERROR phase=implementation reason=tampered`.
- **`Stages::Review.run!#spawn_fix_agent`** — wraps Phase 4. Includes the per-pass `escalations-NN.md` so a fix agent rewriting it (e.g., flipping `[ ]` → `[x]` to short-circuit human review) trips `REVIEW_ERROR phase=fix reason=fix_tampered`.
- **`Stages::Review::Triage.run!`** — wraps the triage spawn (`PROTECTED_FILES = ORCHESTRATOR_OWNED`). Triage may edit reviewer files in place but must NOT touch plan.md / worktree.yml / task.md. Tampering yields `REVIEW_ERROR phase=triage reason=triage_tampered`.
- **`Stages::Review::CiFix.run!`** — wraps each CI-fix attempt. Tampering yields `Result.new(status: :error, error_message: "ci fix agent modified protected files: …")` which the runner translates to `REVIEW_ERROR phase=ci`.

## Why these three files

- `plan.md` — the implementation contract. A fix agent that rewrites the plan is rewriting its own job description.
- `worktree.yml` — the runner's pointer into the project's worktree. Mutating it would re-direct subsequent spawns.
- `task.md` — carries the marker. The orchestrator owns every terminal marker; a sub-agent writing one would short-circuit the state machine.

Reviewer-owned files (`reviews/<reviewer>-NN.md`) are NOT in this set: triage's job is to edit them in place. The escalations file is added to the snapshot at fix-time so triage owns it but the fix agent cannot touch it.

## Tests

- Coverage is co-located with the consumers: `test/unit/stages/review/triage_test.rb` (parameterized over every name in `ORCHESTRATOR_OWNED`), `test/integration/run_review_test.rb` (fix tampering), `test/integration/run_execute_test.rb` (4-execute tampering).

## Backlinks

- [[stages/execute]] · [[stages/review]]
- [[decisions]] (ADR-013)
