---
title: 5-open-pr stage
type: stage
source: lib/hive/stages/open_pr.rb, lib/hive/github_publication.rb, templates/open_pr_prompt.md.erb
created: 2026-05-13
updated: 2026-08-21
tags: [stage, pr, github]
---

**TLDR**: The stage asks an agent only to author a bounded title/body draft.
`Hive::GithubPublication` exclusively inventories the branch, pushes the exact
commit, creates or adopts the draft pull request, and records durable recovery
state. Patrol Fix uses the same controller.

## Preconditions

1. `worktree.yml` is the controller-owned pointer produced by 4-execute.
2. The pointed worktree is registered, clean, on the exact task branch, ahead
   of the configured base, and has a bounded exact binary diff.
3. Git and GitHub repository identities resolve to the same host/repository.

## Stage/controller split

`Stages::OpenPr` owns local workflow policy:

- read and validate `worktree.yml`;
- reuse or author strict `pr-draft.json` containing only `title` and `body`;
- construct and revalidate the exact publication request before every remote
  phase;
- map controller results to `pr.md`, markers, and merged-task completion.

The authoring prompt forbids `git push`, `gh`, remote-state claims, and edits
outside `pr-draft.json`. The agent never writes `pr.md` or a completion marker.

`Hive::GithubPublication::Controller` owns all remote effects:

- secret-scan title, body, and exact diff;
- query only the repository/head-branch PR inventory;
- adopt exactly one canonical marker/title/body/base/head match;
- reject foreign branches and ambiguous candidates;
- push only with an expected-absence lease and verify the remote OID;
- create the PR only after intent is durable and exact local/remote evidence is
  revalidated;
- safely retry a failed absent-branch push or a definite `gh pr create`
  failure; unknown attempted outcomes remain reconciliation-only.

The durable controller state stores identities and digests, never raw title,
body, or diff bytes.

## Outcomes

- OPEN or DRAFT exact PR: write canonical `pr.md` and `pr_opened_draft`.
- MERGED exact PR: write `pr.md`, `summary.md`, and downstream terminal markers.
- CLOSED exact PR: fail closed.
- Conflict, secret, ambiguous inventory, or unknown remote outcome: write an
  attributed `github_publication_*` error and leave the task retryable.

## Backlinks

- [[stages/execute]] · [[stages/review]] · [[state-model]] · [[modules/patrol]]
