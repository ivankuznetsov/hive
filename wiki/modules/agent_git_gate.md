---
title: Hive::AgentGitGate
type: module
source: lib/hive/agent_git_gate.rb, lib/hive/agent_git_gate/isolation.rb, lib/hive/managed_git.rb
created: 2026-07-26
updated: 2026-08-27
tags: [git, security, publication, worktree, boundary]
---

**TLDR**: `Hive::AgentGitGate` is the boundary-ready, clean-loadable Git
mechanism used after an agent has edited a repository. It exposes a closed set
of hardened reads, private agent Git metadata with guarded adoption, exact
detached materialization, remote-ref observation, and expected-OID publication
with immutable receipts. Hive owns credentials, transport permission, branch
and PR policy, durable mutation intent, and operator approval.

## Supported entry point

```ruby
require "hive/agent_git_gate"
```

The supported facade is `Hive::AgentGitGate`. `Hive::ManagedGit` is its private
process executor; production consumers may not require it or submit raw Git
argv directly.

## Public values

| Value | Meaning |
|-------|---------|
| `ReadResult` | One closed read operation with immutable stdout/stderr, exit status, and bounded-output flag. Exit status remains data because ancestry uses status 1 for a normal false result. |
| `RemoteObservation` | Exact branch/ref/OID observation plus a SHA-256 fingerprint of the resolved transport target. It never stores the remote URL or credentials. |
| `MaterializationReceipt` | Exact commit, root-confined destination, and `created`/`existing` disposition for a verified detached clean worktree. |
| `PublicationReceipt` | Expected, before, published, and independently observed after OIDs plus the non-secret remote fingerprint. |
| `IsolatedMetadata` | Exact source repository, worktree, private Git directory, attached branch, and base OID prepared for one managed agent launch. |
| `AdoptionReceipt` | Exact base and imported descendant OIDs after a guarded local branch adoption. |

Typed failures are `InvalidRequest`, `UnsupportedOperation`, `CommandFailed`,
`RemoteConflict`, `MaterializationFailed`, `PublicationFailed`, and
`IsolationFailed`.

## Closed operations

`read(repository, operation, ...)` accepts only declared shapes for current
branch, exact HEAD/commit identity, ancestry, commit count/list, object
type/size/content, strict status (including dirty submodules), changed paths,
raw changed-path metadata, diffs, commit patches, and worktree inventory. The
raw form retains destination modes and rename pairs so evidence-range consumers
can reject symlinks and bind the current destination path without raw Git argv.
Callers cannot supply Git options, helper paths, config entries, or environment
names. Unknown operations or parameters fail before process spawn. Bounded
reads kill the Git process group when stdout exceeds the declared cap.

`remote_urls` reads one named remote through the same process boundary.
`observe_remote_branch` resolves a named remote to exactly one fetch URL, or
accepts an explicit allowed transport, and validates one exact
`refs/heads/<branch>` response.

`tracked_gitlinks(repository_path, max_stdout_bytes: 64 * 1024)` is the only
submodule-discovery operation exposed to production callers. It delegates to a
fixed bounded `ls-files --stage -z` read and returns validated relative gitlink
paths; it is not a general Git command or configuration interface.

`materialize` verifies an already-present commit OID, constrains the destination
below an explicit root, creates a detached worktree, and verifies exact HEAD,
detachment, and cleanliness. It reuses only an exact clean match and prunes
only a stale registration for the same missing destination.
`materialize_remote` additionally binds a `RemoteObservation` to the
re-resolved remote fingerprint, fetches the observed ref, refuses movement,
and then materializes the observed immutable OID.

`remove_materialization` first proves that the root-confined destination is
registered to the requested repository. Normal removal remains non-forcing;
Hive-owned disposable callers may request force removal so formatter or test
output can be discarded without leaving a registered worktree behind. The
force flag is a strict boolean and does not relax destination confinement or
registration ownership.

`prepare_isolated_metadata` proves that the supplied worktree belongs to the
source repository, captures its attached branch and exact HEAD, initializes a
private Git directory below a declared temporary root, configures only its fixed non-bare worktree identity, reads source objects through an alternates file, and builds a private index without moving the controller branch. `adopt_isolated_metadata` accepts only a clean committed descendant. It imports the exact private HEAD without writing `FETCH_HEAD`, resolves that exact object and re-proves ancestry in the authoritative repository with replace objects disabled, revalidates the controller branch and base, updates the worktree index, and moves the source ref with an expected-old-OID compare-and-swap. Any failure through final authoritative status proof rolls back the ref with an expected-head lease and restores the base index; typed diagnostics preserve the original and rollback failures. A receipt is returned only after the authoritative worktree is clean at the adopted commit.

`publish` requires either an exact expected remote OID or exact expected
absence. It resolves the local commit, captures one exact push target, observes
the branch, pushes
`<immutable-oid>:refs/heads/<branch>` with an exact force-with-lease, observes
again, and returns a receipt only when the remote names the published OID.
`publish_local_branch` is the Hive compatibility adapter: it resolves the local
branch once and delegates its immutable OID to `publish`.

## Process hardening

The private executor clears inherited Git config and arbitrary executable
selectors, reduces the environment to an allowlist, disables terminal prompts,
and supplies fixed config that neutralizes:

- repository hooks and fsmonitor;
- replace-object interpretation;
- external diff, textconv, pager, and interactive diff filters;
- repository-selected clean/smudge/process filters, URL rewrites, credential
  helpers, and custom remote upload/receive programs (the operation refuses
  repository-local executable config before spawn, including config reached
  through local `include` directives; an unreadable or otherwise uninspectable
  config fails closed; private-metadata import also refuses
  `uploadpack.packObjectsHook`);
- repository-selected HTTP transport policy, alternate-ref commands, and
  working-tree redirection;
- inherited credential, SSH-command, askpass, and config-count helpers; and
- `ext` and `file` transports by default.

HTTPS credentials are delegated to `gh auth git-credential`; embedded HTTPS
userinfo is refused. Services can pin the helper to an absolute executable with
`HIVE_GH_BIN`; invalid or non-executable overrides fail before Git starts, while
an unset override preserves the normal `PATH` lookup. Remote observation,
fetch, and publication share a 60-second wall-clock deadline that covers Git
and inherited credential-helper pipes. Expiry terminates the complete process
group so a stuck helper cannot retain daemon capacity indefinitely. SSH and Git
URLs may carry a username but not embedded
passwords, and explicit transport ports remain valid. SSH may use the
controller's agent socket. A caller can explicitly permit local file transport
only for a scoped operation. Hive's `Gh` compatibility adapter accepts that
injected policy from `agent_git_gate.allow_local_transport: true`; it is used
for deliberate local/bare-remote workflows and remains false by default. The
target is still passed as an argv element and `ext` remains forbidden.

Receipts contain target fingerprints, not URLs, command output, environment
values, or credentials. Errors deliberately retain bounded generic operation
details rather than potentially credential-bearing transport output.

## Hive adapters

- `Hive::Gh` translates managed remote observation and exact publication into
  its compatibility `GhError` / `PushResult` contracts. Ordinary GitHub API and
  PR policy remain outside the component.
- Managed draft-PR AgentReport and handoff use the closed read vocabulary,
  exact absence publication, and root-confined cleanup.
- Patrol Fix publication delegates its exact worktree reads, expected-absence
  branch push, and idempotent cleanup through the gate. The separate
  `Hive::GithubPublication` controller owns durable PR identity and replay;
  `AgentGitGate` still knows nothing about GitHub records or workflow stages.
- Patrol Fix validation materializes the receipt-bound fix HEAD in a private
  detached checkout and force-discards that exact registered materialization
  after commands finish or raise. If removal fails, Validate preserves the
  original outcome and warns with the retained checkout path for operator
  recovery. Its authoritative patch checkout is never the validation command
  working directory.
- Managed Patrol Fix agents compose the gate with
  `PatrolFix::AgentGitIsolation`: every launch writes Git config, refs, objects,
  and index state only in private metadata. A successful Fix report may adopt
  an exact clean descendant through this gate; Inbox and Review never adopt.
- Refactor patrol captures one managed push URL, uses managed remote
  observations, and publishes through the exact expected-OID/absence gate.
  Its append-only action ledger remains the authority deciding which old OID is
  replaceable.
- Outcome evidence resolves its clean controller-owned base-to-head range
  through bounded status, ancestry, exact-commit, and raw changed-path reads;
  it never invokes the private Git executor directly.
- `Hive::Worktree#create_detached_exact!` delegates exact analysis-tree
  materialization while preserving its `created`/`existing` return contract.

## Guarantee limits

This boundary hardens controller Git process execution and ref authority. It
does not by itself confine arbitrary same-user code, monitor writes, sandbox
the agent, validate patch meaning, authorize a mutation, own PR state, or make
repository data trustworthy. Patrol's separate mount adapter supplies targeted
pre-spend filesystem prevention for real Git metadata and user Git config.
Agent invocation guarantees otherwise belong to `Hive::AgentRuntime`;
protected-output custody belongs to `Hive::ArtifactFirewall`.

## Tests

- `test/unit/agent_git_gate_test.rb` uses real repositories and bare remotes for
  exact absence/OID leases, before/after receipts, ref-movement refusal,
  detached materialization, destination confinement, dirty disposable
  force-removal, forbidden transports, unknown-operation rejection, immutable
  values, helper suppression, private-metadata preparation, stale-source and
  dirty/private-history refusal, exact no-`FETCH_HEAD` import, authoritative
  replace-free ancestry proof, exact adoption, compare-and-swap loss, index
  restoration, final clean-postcondition rollback proof, and the narrow
  tracked-gitlink facade.
- `test/unit/managed_git_test.rb` pins environment/config/command hardening,
  absolute credential-helper selection, bounded fixed gitlink discovery,
  fixed private-worktree configuration, and deadline process-group cleanup.
- `test/unit/gh_test.rb`, `test/unit/worktree_test.rb`,
  `test/unit/stages/agent_report_test.rb`,
  `test/unit/stages/draft_pr_handoff_test.rb`,
  `test/unit/github_publication_test.rb`, and
  `test/unit/stages/open_pr_test.rb` pin the Hive adapters.
- `test/unit/component_boundaries_test.rb` proves clean loading and rejects
  production `Hive::ManagedGit` bypasses.
- `test/unit/patrol_fix/agent_git_isolation_test.rb` proves the composing mount
  boundary with regular and linked worktrees and malicious Git writes.

## Backlinks

- [[component-boundaries]]
- [[modules/gh]] · [[modules/worktree]] · [[modules/git_ops]]
- [[commands/refactor-patrol]]
