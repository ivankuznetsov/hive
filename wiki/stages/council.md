---
title: Council Stage Runner
type: stage
source: lib/hive/stages/council.rb, lib/hive/stages/council/*.rb, templates/council_reviewer_prompt.md.erb, templates/council_revise_prompt.md.erb
created: 2026-07-08
updated: 2026-07-08
tags: [stage, council, workflow, review]
---

**TLDR**: `Hive::Stages::Council` is the generic document review council for
project-authored workflows. It reviews a target artifact with multiple
descriptor-declared reviewers, writes per-reviewer files under `reviews/`,
aggregates a triage artifact, and marks the stage `COMPLETE` on quorum or
`WAITING` when revision/human input is needed.

## Runtime Contract

1. Resolve the current descriptor stage from `task.workflow`.
2. Resolve the review target from `stage.input`, or from the previous stage's
   `state_file` when `input` is omitted.
3. For each round, set `AGENT_WORKING phase=council round=N`.
4. Run each reviewer:
   - agent reviewers spawn through `Hive::Stages::Base.spawn_agent` with
     `status_mode: :output_file_exists` and expected output
     `reviews/<output_basename>-NN.md`;
   - command reviewers run with `HIVE_COUNCIL_INPUT`,
     `HIVE_COUNCIL_OUTPUT`, and `HIVE_COUNCIL_ROUND`.
5. Deterministic triage parses reviewer verdicts, writes
   `reviews/triage-NN.md`, updates the configured latest triage file, and
   records verdicts, accepted findings, rejected findings, required edits,
   open disagreements, and readiness.
6. If ready reviewers meet `quorum`, write `COMPLETE`.
7. If not ready:
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
multi-round revise loops, max-round waits, missing input errors, and command
reviewers. `test/integration/architecture_workflow_e2e_test.rb` proves the
reference architecture workflow reaches an agent-terminal `architecture.md`
deliverable without a dummy final stage.

## Backlinks

- [[modules/workflows]]
- [[stages/agent]]
- [[modules/task_action]]
