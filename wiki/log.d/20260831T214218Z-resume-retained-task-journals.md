---
title: Resume retained tasks through their cutover checkpoint
tags: [runtime-control-plane, cutover, task-journal, projection, lifecycle]
---

Ordinary lifecycle projection reads previously ignored the retained cutover
checkpoint and replayed the complete journal. Because the all-in cutover
intentionally reset legacy attempt rows, a resumed task could complete its
stage action and then fail while computing the next action on the journal's
first historical attempt.

Lifecycle reads now prefer the authenticated checkpoint prefix and validate
only its bounded append-only suffix against SQLite. If that path is unavailable
or invalid, Hive falls back to the original strict full replay. Explicit
rebuild remains strict. Exact-task repair may reconstruct a missing checkpoint
from a retained snapshot only for pre-activation attempt bindings, after a
pre-activation observation for that attempt is also present in the journal and
after a complete journal replay and projection match. A changed journal, unrelated
projection drift, or missing post-activation attempt still fails closed.
