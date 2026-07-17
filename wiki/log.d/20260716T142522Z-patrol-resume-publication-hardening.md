# Ordinary patrol resume and publication hardening

Ordinary patrol now records an explicit active review snapshot, so a provider or
contract error in the first feature batch pins the attempted SHA even while its
cursor remains zero. A later default-branch commit cannot silently replace that
incomplete review; the next cycle finishes the durable snapshot first.

Created pull requests now enter a retryable `reconciliation_pending` state with
an exact PR URL and validated patch/base/head/worktree receipt. Lookup lag,
authentication failure, dismissal reconciliation, or restart reuses only that
patch and does not suppress the finding. The fingerprint becomes `open` only
after exact hosted identity and review handoff settle.

Fix-proof ingestion now opens agent-controlled output without following links,
uses nonblocking reads, rejects non-regular files, and retains the 64 KiB cap,
preventing symlink or FIFO output from escaping or stalling the fixer.
