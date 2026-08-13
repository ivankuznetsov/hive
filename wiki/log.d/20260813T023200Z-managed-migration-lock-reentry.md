---
title: Keep managed migration marker backfill inside one mutation lock
---

- Resolve pinned managed recovery state files from their descriptor and
  unpinned tasks from a workflow generation captured before the transaction.
- Prevent `hive migrate --all` from reacquiring its own non-reentrant managed
  workflow mutation lock while backfilling marker identities.
- Add regression coverage for both pinned and unpinned task resolution at this
  locked migration boundary.
