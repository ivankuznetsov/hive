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

This document is the producer's bounded-search and missing-evidence record.
The Hive follow-up destinations above are verified. Their idea bodies still do
not attach this record, because this change touched only the C4 consumer task.

## Attached consumer evidence

On 2026-09-28 this record was attached to the hivedev C4 consumer task:

- Task slug: `c4-implement-durable-command-operations-260923-9817`
- Task body: `.hive-state/stages/1-inbox/c4-implement-durable-command-operations-260923-9817/idea.md`
  in the hivedev repository, section "Comparison evidence from hive PR #1494"
- hivedev state commit: `f54b9b998b4d9b83799283ef175d54e0cee5b2b2` on the
  `hive/state` branch (local state branch, not published to the hivedev remote)
- Referenced producer commit: `7de98ab33cdc70f2c0359a24b4220e86656b22d9`
  (`ivankuznetsov/hive`, PR #1494)

The attachment leaves the task's `WAITING` marker unchanged. It does not change
the comparison outcome, which remains **unavailable** until C4 supplies a
concrete request/response mapping.
