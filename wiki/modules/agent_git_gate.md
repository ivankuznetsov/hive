---
title: Hive::AgentGitGate
type: module
source: lib/hive/agent_git_gate.rb, lib/hive/managed_git.rb
created: 2026-07-26
updated: 2026-07-27
tags: [git, security, publication, worktree, boundary]
---

**TLDR**: `Hive::AgentGitGate` is the boundary-ready, clean-loadable Git
mechanism used after an agent has edited a repository. It exposes a closed set
of hardened reads, exact detached materialization, remote-ref observation, and
expected-OID publication with immutable receipts. Hive owns credentials,
transport permission, branch and PR policy, durable mutation intent, and
operator approval.

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

Typed failures are `InvalidRequest`, `UnsupportedOperation`, `CommandFailed`,
`RemoteConflict`, `MaterializationFailed`, and `PublicationFailed`.

## Closed operations

`read(repository, operation, ...)` accepts only declared shapes for current
branch, exact HEAD/commit identity, ancestry, commit count/list, object
type/size/content, status, changed paths, diffs, commit patches, and worktree
inventory. Callers cannot supply Git options, helper paths, config entries, or
environment names. Unknown operations or parameters fail before process spawn.
Bounded reads kill the Git process group when stdout exceeds the declared cap.

`remote_urls` reads one named remote through the same process boundary.
`observe_remote_branch` resolves a named remote to exactly one fetch URL, or
accepts an explicit allowed transport, and validates one exact
`refs/heads/<branch>` response.

`materialize` verifies an already-present commit OID, constrains the destination
below an explicit root, creates a detached worktree, and verifies exact HEAD,
detachment, and cleanliness. It reuses only an exact clean match and prunes
only a stale registration for the same missing destination.
`materialize_remote` additionally binds a `RemoteObservation` to the
re-resolved remote fingerprint, fetches the observed ref, refuses movement,
and then materializes the observed immutable OID.

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
- external diff, textconv, pager, and interactive diff filters;
- repository-selected clean/smudge/process filters, URL rewrites, credential
  helpers, and custom remote upload/receive programs (the operation refuses
  repository-local executable config before spawn, including config reached
  through local `include` directives; an unreadable or otherwise uninspectable
  config fails closed);
- repository-selected HTTP transport policy, alternate-ref commands, and
  working-tree redirection;
- inherited credential, SSH-command, askpass, and config-count helpers; and
- `ext` and `file` transports by default.

HTTPS credentials are delegated to `gh auth git-credential`; embedded HTTPS
userinfo is refused. SSH and Git URLs may carry a username but not embedded
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
- Refactor patrol captures one managed push URL, uses managed remote
  observations, and publishes through the exact expected-OID/absence gate.
  Its append-only action ledger remains the authority deciding which old OID is
  replaceable.
- `Hive::Worktree#create_detached_exact!` delegates exact analysis-tree
  materialization while preserving its `created`/`existing` return contract.

## Guarantee limits

This boundary hardens controller Git process execution and ref authority. It
does not confine arbitrary same-user code, monitor writes, sandbox the agent,
validate patch meaning, authorize a mutation, own PR state, or make repository
data trustworthy. Agent invocation guarantees belong to
`Hive::AgentRuntime`; protected-output custody belongs to
`Hive::ArtifactFirewall`.

## Tests

- `test/unit/agent_git_gate_test.rb` uses real repositories and bare remotes for
  exact absence/OID leases, before/after receipts, ref-movement refusal,
  detached materialization, destination confinement, forbidden transports,
  unknown-operation rejection, immutable values, and helper suppression.
- `test/unit/managed_git_test.rb` pins environment/config/command hardening.
- `test/unit/gh_test.rb`, `test/unit/worktree_test.rb`,
  `test/unit/stages/agent_report_test.rb`,
  `test/unit/stages/draft_pr_handoff_test.rb`, and
  `test/unit/refactor_patrol/pr_opener_test.rb` pin the Hive adapters.
- `test/unit/component_boundaries_test.rb` proves clean loading and rejects
  production `Hive::ManagedGit` bypasses.

## Backlinks

- [[component-boundaries]]
- [[modules/gh]] · [[modules/worktree]] · [[modules/git_ops]]
- [[commands/refactor-patrol]]
