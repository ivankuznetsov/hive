## Remove unused PR merge backlog count

- Removed `Daemon::PrMergeWatcher#pending_count`, whose only callers were
  three direct unit assertions, together with its now-unreachable private
  `each_candidate` traversal.
- Retained the surrounding durable candidate, held-row, invalid-URL, backlog,
  and outcome assertions through the watcher's live observation surfaces.
