# ADR-031: Document Council Workflows

## Status

Accepted.

## Context

Project-authored workflows need review councils for non-code documents such as
architecture plans. The existing coding review runner is coupled to worktrees,
diffs, CI repair, PR metadata, protected-file checks, and publish/finalize
behavior. Reusing it directly for document review would force document
workflows through coding-specific state and increase regression risk in the PR
pipeline.

## Decision

Hive supports `kind: council` as a separate, document-oriented runner:

- reviewers run over a target file and write `reviews/<name>-NN.md`;
- deterministic triage writes `reviews/triage-NN.md` and the configured latest
  triage artifact;
- quorum, `max_rounds`, `exit_rule`, and optional revise agent control the loop;
- council stages reuse generic `AGENT_WORKING`, `WAITING`, `COMPLETE`, and
  `ERROR` markers.

The coding `:review_council` stage keeps its bespoke runner. Shared concepts are
limited to artifact naming, output-file validation, triage summaries, and marker
ownership.

## Consequences

Custom workflows can express document review without prompt-encoded reviewer
panels or dummy terminal stages. The first implementation deliberately avoids
weighted quorum and role-specific pass rules; those can be added after a second
consumer proves the need.
