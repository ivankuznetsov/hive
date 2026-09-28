# C4 command-contract comparison

Comparison date: 2026-09-28. Implementation base:
`f3de256100aaa9cb4dbc6f9bc9b0b6f8901b314d`.
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

The native Hive registry was queried on 2026-09-28 and verifies that all three
durable follow-up destinations already exist:

| Contract | Durable reference | Slug | Current stage |
| --- | --- | --- | --- |
| Receipt redrive | `hive:43362` | `follow-up-to-extend-idempotency-260926-86b8` | `1-inbox` |
| General adjudication UX | `hive:43363` | `follow-up-to-extend-idempotency-260926-5ad8` | `1-inbox` |
| Multi-host/decommission hardening | `hive:43364` | `follow-up-to-extend-idempotency-260926-e467` | `1-inbox` |

This document is the producer's bounded-search and missing-evidence record. The
worktree-only execution boundary does not authorize editing those external task
artifacts, and their current idea bodies do not attach this record. An
authorized Hive task-artifact update must attach or link this comparison to the
appropriate follow-up before claiming the Tier A evidence-bearing-task
deliverable is complete. The durable identities above are verified; the
attachment is not.
