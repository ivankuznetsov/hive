## [2026-07-27T20:30:00Z] release - add trusted exact-SHA candidate workflow

**Action:** Added protected-main candidate dispatch, exact remote identities,
action-lock enforcement, bounded collection states, authenticated staged
upgrade inputs, closed blocking aggregation, and a checkout-free final Check
Run publisher. Candidate and evidence artifacts retain for 30 days; live-agent
proof remains advisory.

**Safety:** No workflow was dispatched and no historical package, provider
credential, version choice, tag, publication, deployment, or release action was
used during implementation.

**Retry:** Targeted retry now resolves named, failed, or missing display names
from digest-bound predecessor evidence, executes only selected replacements,
and composes their immutable trusted-control receipts with unchanged
predecessor rows. Candidate artifact producer identity survives chained
attempts; failed attempts still retain `qa_blocked` evidence and publish a
digest-bound failed Check Run.
