---
title: Proposal source workers bind and report failures
type: change
created: 2026-11-09
updated: 2026-11-09
tags: [proposals, attempts, cli]
---

`hive proposal submit|evaluate` source workers now pass durable attempt context
validation: `Attempts::Context` binds the `hive proposal submit|evaluate TASK`
worker argv to the admitted task and its current stage, so a dispatched source
attempt reaches the Producer instead of being refused before CLI dispatch. The
controller now applies the shared `Attempts::CommandDispatch` attach-result
policy (extracted as `interpret_durable_result!`), so a failed or lost worker
exits non-zero and `--json` still yields one document. Producer restores the
committed proposal namespace under the commit lock before its source-ID retry
lookup, so direct service callers ignore crash-left receipts. `Producer.for_task`
reuses a proposal binding only inside the authenticated worker of the task's
live admitted attempt; previously a second `submit`/`evaluate` on the same task
silently reused the finished earlier attempt's subject (or proposal ID) and
ignored the new typed options. The unrelated web
system-test assertion swept in by an earlier residue commit is reverted, and the
unused `SourceEventStore#write_index_unlocked` helper is removed.
