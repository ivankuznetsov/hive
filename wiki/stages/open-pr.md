---
title: 5-open-pr stage
type: stage
source: lib/hive/stages/open_pr.rb, lib/hive/github_publication.rb, templates/open_pr_prompt.md.erb
created: 2026-05-13
updated: 2026-11-20
tags: [stage, pr, github]
---

**TLDR**: The stage asks an agent only to author a bounded title/body draft.
`Hive::GithubPublication` exclusively inventories the branch, pushes the exact
commit, creates or adopts the draft pull request, and records durable recovery
state. Patrol Fix uses the same controller.

## Preconditions

1. `worktree.yml` is the controller-owned pointer produced by 4-execute.
2. The pointed worktree is registered, clean, on the exact task branch, ahead
   of the configured base. There is no total patch-size gate.
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
For OpenCode, that contract is enforced independently of project permissions:
the generated invocation allows an edit only to the exact `pr-draft.json`
path and denies Bash. This prevents a broad project-level shell rule from
bypassing its external-directory policy to reach host Git credentials
or perform a second publication path. The provider-support facade supplies
that provider-specific scope and completion policy, leaving the stage
provider-neutral. A strictly parsed, complete draft is
also a controller-owned completion signal: Hive gives OpenCode five seconds to
exit normally, then terminates a trailing empty provider turn and continues
without waiting for the stage timeout. Partial or invalid JSON cannot trigger
that path.

`Hive::GithubPublication::Controller` owns all remote effects:

- use bundled Betterleaks to scan title, body, and all commits in the exact
  unpublished range, including credentials added then removed;
- query only the repository/head-branch PR inventory;
- adopt exactly one canonical marker/title/body/base/head match;
- reject foreign branches and ambiguous candidates;
- push only with an expected-absence lease and verify the remote OID;
- create the PR only after intent is durable and exact local/remote evidence is
  revalidated;
- after review or artifact rework, fast-forward the same controller-owned draft
  only when its original number, URL, repository, base, and branch are
  unchanged, the hosted head still equals the remote branch, and that head is
  an ancestor of the new local commit. Title and body edits do not change the
  identity. The one accepted base change is a GitHub retarget of a stacked PR
  after its prerequisite merged (see [[publication-recovery]]);
- safely retry a failed absent-branch push or a definite `gh pr create`
  failure; unknown attempted outcomes remain reconciliation-only.

The durable controller state stores identities and digests, never raw title,
body, or diff bytes. A rework fast-forward keeps the first observed publication
state as its immutable ownership anchor. Its expected-remote-OID push is safe to
reconcile after a lost response, while a changed/ambiguous PR, non-fast-forward
head, rewritten hosted history, remote mismatch, or merged PR missing the new
revision fails closed.

A controller-owned PR closed unmerged before the new revision was hosted (for
example an owner closing a placeholder PR, then the task re-running) gets a
successor publication. The controller records the closed PR as
`superseded_pr`, leases the push to the branch's last published head (or to an
absent branch), requires the new head to contain it, and creates a new PR.
A branch that moved after the last publication still fails closed with
`revision_hosted_terminal`.

The pointer's creation OID remains provenance. The actual change range starts
at the merge-base of the intended PR base branch and the exact candidate HEAD;
it must not include unrelated upstream history merely because a task is old.
Open PR and outcome-evidence identity use `AgentGitGate.change_base` for this
calculation. Remote-tracking refs are preferred; local base refs support offline
repositories. Frozen repair receipts and Patrol review receipts keep their exact
reviewed ranges rather than silently changing approval identity.

Legacy pointers without a creation OID bind their first publication to the
verified PR merge-base without rewriting the pointer. Publication hashes the
diff incrementally; its request holds OIDs and a digest, not the full patch.
Revalidation still checks the exact candidate and change range before effects.

## Outcomes

- OPEN or DRAFT exact PR: write canonical `pr.md` and `pr_opened_draft`.
- MERGED exact PR: write `pr.md`, `summary.md`, and downstream terminal markers.
- CLOSED exact PR at the current head: fail closed. Closed before the current
  head was hosted: publish a successor PR (see above).
- Conflict, secret, ambiguous inventory, or unknown remote outcome: write an
  attributed `github_publication_*` error and leave the task retryable.
- Authoring agent hit a provider limit: `ERROR reason=limits_reached
  provider=<agent>`, retried by the daemon after the shared cooldown.

## Provider-limit fallback

Field case (2026-11-20): hivedev task `adr-0004-rollout-step-3-261115-9cdb`
failed `limits_reached` on every scheduled retry because its open_pr identity
was already resolved to Codex for the generation, while Codex was out of quota
for three days and the project config had been rerouted to grok.

With the opt-in `implementation.limit_fallback` (see [[modules/config]]), an
authoring run that would write `limits_reached` is retried once on the mapped
fallback profile under fresh custody. The primary's partial `pr-draft.json`
is deleted first. The substitute identity is `open_pr.agent` / `model` /
`effort` when `open_pr.agent` names the fallback, else the fallback profile's
default model at the stage's `medium` effort. It is journaled as
`implementation_identity_substituted` before launch, with log label
`open-pr-author-fallback-<agent>` and no route observation. The open_pr pin
for the generation is unchanged, so every attempt starts on the primary. A
successful substitute's draft feeds the same publication controller. A
substitute that is also limited or fails, a short reset (`waiting`), an
unresolvable identity (`unresolved`), or a failed journal append (`failed`)
keeps the primary's `limits_reached` marker annotated with `primary_agent=`,
`fallback_agent=`, and `fallback_outcome=`. Refused models and generic
authoring failures never fall back. See [[stages/execute]] for the shared
rules.

## Backlinks

- [[stages/execute]] · [[stages/review]] · [[state-model]] · [[modules/patrol]]
