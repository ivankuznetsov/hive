---
title: Recover verification checkpoint-custody false positives
tags: [plan-review, verification, recovery, task-projection]
---

The plan-review checkpoint-custody rollout recovery covered primary and
adversarial reviewers but omitted disposition verification. Historical
verification rows carrying the same exact runner-authored false positive could
therefore retry forever even though the current firewall already excluded the
orchestrator checkpoint.

The versioned recovery contract now covers verification as well. It resets
only the exact historical diagnostic once; malformed metadata, unrelated
custody failures, and failures after the current reset still fail closed.
