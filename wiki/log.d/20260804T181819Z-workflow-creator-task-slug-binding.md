---
title: Bind Workflow Creator execution to the created task slug
type: change
created: 2026-08-04
tags: [workflow-creator, execution, evidence]
---

The Workflow Creator semantic contract no longer assumes a fixed task slug.
Its nine-command vocabulary gives every position an exact semantic label and
represents the run target as `{created_slug}`. Execution receipts must prove
that argument 1 of command position 7 was bound from the `slug` result field of
task-creation position 6, and the primary task row must carry the same slug.

Focused core, proof-bundle, and deterministic smoke coverage resolve a realistic
generated slug before validating exact argv and reject command-label or binding
substitution.
