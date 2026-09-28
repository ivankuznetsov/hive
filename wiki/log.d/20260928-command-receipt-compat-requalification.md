---
date: 2026-09-28
title: Requalify the command-receipt compatibility candidate
---

- Rebuild the pinned-baseline compatibility candidate with the current patch,
  whose 31-object inventory already includes the installation-wide capacity
  aggregate. The candidate SHA-256 changes from `4ac48a4a…` to `ddc5ecca…`.
- Repeat the isolated rollback/re-upgrade drill on a fresh database. It passed:
  the candidate returned status `ok` and completed global maintenance dispatch
  cycles with the extension and a receipt present, the current runtime replayed
  the receipt without executing the body, and an altered extension failed
  closed with `partial_schema`.
- Update the proof, the migration guide, the pinned proof test, and the
  `wiki/gaps.md` command-receipt section so they agree.
- Attach the C4 comparison record to hivedev task
  `c4-implement-durable-command-operations-260923-9817` (hivedev state commit
  `f54b9b99`). Record that durable reference in
  `docs/command-receipts-c4-comparison.md` and `wiki/gaps.md`.
