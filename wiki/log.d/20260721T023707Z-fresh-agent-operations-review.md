## [2026-07-21T02:37:07Z] operations — close the fresh agent-operations review

**Action:** Re-ran the review against the exact current feature diff and closed
its remaining agent-facing contract gaps. Partial `hive act --json` usage
failures now retain available action/target identity, and `hive watch` bounds
status fetches, rejects ambiguous physical rows with stage/folder evidence,
pins durable task ids across slug reuse, and safely adopts a daemon-backfilled
id only when the selected task directory keeps the same device/inode identity.
The same overall deadline bounds status reads and physical-identity lookups, so
a blocked task path cannot publish a late transition or terminal result, while
an upstream timeout remains a source failure rather than impersonating that
deadline.
Daemon snapshots preserve durable admission outcomes, use completion-anchored
validity with SIGHUP reconfiguration, reject duplicate project/slug source rows
before any overlay becomes authoritative, and scope recovery exhaustion to the
current stage and marker reason.

**Release proof:** Claude evidence now requires the typed native `system/init`
skill and slash-command inventories, so generic file access cannot pass. The
tag workflow invokes the fixture-tested selector for Check Run, workflow/run,
job, artifact expiry, and downloaded archive-digest verification instead of
relying on string-fragment assertions.

**Uncertainty:** The authenticated protected workflow has not yet been
dispatched for this candidate. Until all four native jobs and attestation pass
and the exact-SHA Check Run exists, the implementation is locally validated but
not release-proven. No tag, package release, ClawHub publish, or deployment was
performed.

**Hosted CI follow-up:** Exact-head coverage exposed integration contracts that
the focused suites had not exercised. Scheduler `mtime` is now distinct from
action-token `observation_mtime`, concise legacy-layout warnings retain exact
directory evidence and grammar, and `Commands::Act` owns missing-token usage
errors so Thor does not truncate unrelated command summaries. The typed act
envelope now also classifies `AmbiguousSlug` before its `InvalidTaskPath`
parent, preserving the closed `ambiguous_target` error vocabulary. Defensive
coverage now exercises watch input/source boundaries, skill inventory and
publication failures, scheduler snapshot joins, and recovery fallbacks. The
TUI snapshot mirrors the additive `observation_mtime` field as well, preserving
its one-to-one compatibility-status mapping for both current and older payloads.
