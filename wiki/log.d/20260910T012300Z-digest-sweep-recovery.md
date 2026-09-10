---
title: Repair daily digest upgrade and replay boundaries
date: 2026-09-10
---

Daily digest initialization now persists legacy registry epochs before taking its
coverage snapshot in the same config transaction. Repeated source outages can
append distinct amendments after recovery, while repeated observations of the
same pruned evidence deduplicate. Explicit ended membership clears retained
boundary attention; dated activity gaps affect their own interval only.

Regression tests cover these cases and preserve immutable closed bases, source
history, and delivery evidence. Missing and pruned delivery inputs are checked
before ledger or transport effects. Web state descriptions use plain wording.
Long-history reader latency remains an explicit measurement gap.
