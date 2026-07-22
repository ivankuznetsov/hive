---
title: Bound LLM-wiki backlog source preservation
type: change
source: .llm-wiki/post-commit-refresh.sh, templates/llm-wiki/post-commit-refresh.sh, lib/hive/llm_wiki_bootstrap.rb
created: 2026-07-22
---

**Action:** Fixed the live Hive LLM-wiki recovery path after an older missing
managed-worktree registration accumulated more than six hundred durable queue
entries and the replacement runner attempted to pin every source in one
five-second `git update-ref --stdin` transaction. Source preservation now uses
independently bounded 64-ref transactions, interrupted temp entries are
reconstructed when their filename identifies an available commit, and config
reconciliation removes a configured `main_wiki_path` after that directory
disappears. Regression tests force ref transactions above two sources to fail,
prove a five-source queue is split `2/2/1`, recover an empty interrupted queue
write, retain it when its commit or changed paths cannot be read, recover from
a later ref-transaction failure without losing queue entries, preserve or
receipt every source, keep both user checkouts clean, rediscover a moved main
wiki, and preserve an existing custom path. Updated [[templates]],
[[commands/init]], [[testing]], and [[gaps]]; page coverage did not change, so
[[index]] did not need a catalog update.

The operator-authorized live recovery reconstructed all five interrupted temp
writes and drained 637 complete entries to zero pending, hidden, or failed
entries. It left no breaker or publication block, published the same refresh
head held locally, preserved a wiki-only branch diff, and kept the primary
checkout clean. Scheduler inventory remained 13 repository-owned units before
and after the drain, all with 4 GiB memory ceilings and none active or failed.
Final QMD maintenance confirmed 688 indexed documents with no outstanding
content-hash embeddings.

Post-recovery verification found that startup reconciliation from an older
linked checkout could still replace the shared runtime with that checkout's
stale scripts. Shared-runtime copies now come from the primary worktree whenever
its managed files exist; linked files are accepted only for a repository's
first bootstrap. An integration test corrupts a linked copy deliberately and
proves that the shared runner and config continue to match the primary.
