# C4 command-contract comparison

Comparison date: 2026-09-27. Producer revision: `882b8e9ead2f9cf5321b158fe47648e6a01a2fca`.
Compared consumer checkout revision: `c98b352` in the locally accessible
`hivedev` checkout.

Outcome: **unavailable**.

A bounded search of Hive `lib/`, `web/app/`, and `wiki/`, and of the accessible
hivedev source and documentation, found architectural references to operation
ids, deduplication, and unresolved outcomes but no concrete C4 command mapping,
request schema, retry-horizon carrier, or expected response fixture. This is
missing evidence, not a confirmed mismatch and not evidence that C4 does not
exist elsewhere.

The producer therefore publishes only this bounded subset: `new`, answer
writes, `approve`, `act`, descriptor-backed stage actions, targeted `archive`,
and terminal-only receipt prune. It makes no all-command or C4 end-to-end
compatibility claim. General adjudication/audit inspection, receipt redrive,
and multi-host/decommission continuity remain the three follow-up contracts.

The execution stage was constrained to edit only this worktree. Hive's native
task-creation workflow writes durable task artifacts under the project state
home outside the worktree, so this attempt could not lawfully create or verify
the required evidence-bearing C4 comparison follow-up task. A durable task id
is intentionally not fabricated here; producer completion remains blocked
until an authorized stage creates that task and records its id in this file.
