---
title: Council Stage Runner
type: stage
source: lib/hive/stages/council.rb, lib/hive/stages/council/*.rb, templates/council_reviewer_prompt.md.erb, templates/council_revise_prompt.md.erb
created: 2026-07-08
updated: 2026-07-09
tags: [stage, council, workflow, review]
---

**TLDR**: `Hive::Stages::Council` is the generic document review council for
project-authored workflows. It reviews a target artifact with multiple
descriptor-declared reviewers, writes per-reviewer files under `reviews/`,
aggregates a triage artifact, and marks the stage `COMPLETE` on quorum or
`WAITING` when revision/human input is needed.

## Runtime Contract

1. Resolve the current descriptor stage from `task.workflow`.
2. Pre-flight resume on the current marker: a `COMPLETE` council short-circuits
   to done without re-spawning reviewers; a `WAITING` council resumes by
   re-triaging the **same** round (from the marker's `round` attr, no round++)
   rather than opening a fresh round.
3. Resolve the review target from `stage.input`, or from the previous stage's
   `state_file` when `input` is omitted.
4. For each round, set `AGENT_WORKING phase=council round=N`. The round counter
   for a fresh run derives from existing `<triage_output_dir>/<basename>-NN.md`
   files, so a custom `triage_output` dir tracks rounds correctly.
5. Run each reviewer (retried up to `max_attempts`, default 1):
   - agent reviewers spawn through `Hive::Stages::Base.spawn_agent` with
     `status_mode: :output_file_exists` and expected output
     `reviews/<output_basename>-NN.md`; descriptor `budget_usd` / `timeout_sec`
     defaults reach every reviewer and revise spawn unless the project YAML
     explicitly overrides that stage key;
   - command reviewers run with `HIVE_COUNCIL_INPUT`,
     `HIVE_COUNCIL_OUTPUT`, and `HIVE_COUNCIL_ROUND`. Reviewer and revise
     commands share a process-group-aware runner bounded by the effective stage
     `timeout_sec`; expiry sends TERM, then KILL after a short grace, and reaps
     the shell.
   - reviewer `name`/`output_basename` must be unique per council (enforced at
     descriptor parse) so two reviewers can't overwrite the same review file.
6. Deterministic triage parses reviewer verdicts, writes
   `reviews/triage-NN.md`, updates the configured latest triage file, and
   records verdicts, accepted findings, rejected findings, required edits,
   open disagreements, and readiness. A reviewer is only counted ready on a
   structured `Verdict:`/`Status:` line; missing the line defaults to not-ready
   (free-text prose is no longer sniffed).
7. If ready reviewers meet `quorum`, write `COMPLETE`.
8. If not ready:
   - `exit_rule: human` or no revise agent writes
     `WAITING reason=needs_revision`;
   - `exit_rule: consensus` with a revise agent loops until quorum or
     `max_rounds`;
   - exhausted consensus loops write `WAITING reason=max_rounds`.

The runner intentionally does not reuse the coding `:review_council` body. That
runner is worktree/diff/CI/PR coupled; the document council shares only artifact
naming, output-file validation, triage, and marker ownership patterns.

## Descriptor Shape

```yaml
- name: review
  kind: council
  state_file: review.md
  input: draft.md
  budget_usd: 25
  timeout_sec: 3600
  council:
    quorum: 2
    max_rounds: 3
    exit_rule: consensus
    triage_output: reviews/triage.md
  reviewers:
    - name: claude-doc
      agent: claude
      prompt: Review the draft.
    - name: codex-doc
      agent: codex
      prompt: Review implementation risk.
```

## Tests

`test/unit/stages/council_test.rb` covers first-round consensus, human waits,
multi-round revise loops, max-round waits, missing input errors, command
reviewers, descriptor resource forwarding to reviewer/revise agents, graceful
and forced command timeout termination, failed-reviewer `:error` markers,
explicit `input:` resolution, resume-after-waiting round continuity, and
`COMPLETE` short-circuiting.
`test/integration/architecture_workflow_e2e_test.rb` proves the
reference architecture workflow reaches an agent-terminal `architecture.md`
deliverable without a dummy final stage.

## Backlinks

- [[modules/workflows]]
- [[stages/agent]]
- [[modules/task_action]]
