---
date: 2026-09-06
slug: patrol-publication-rework-runtime-lease
---

- The receipt-bound publication rework executor now reads its task lease by
  task identity and verifies release after the stage move. This preserves the
  original lock-ownership fence after the runtime-control-plane lease migration
  removed task-folder lock files.
