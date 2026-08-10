---
title: Babysitter provisions its needs-human label
date: 2026-08-08
tags: [babysitter, github, labels, recovery]
---

The PR babysitter no longer assumes every registered repository was manually
seeded with `babysitter/needs-human`. Before its first application to a PR,
`GhOps` now checks for that Hive-owned label with an exact label search and runs
`gh label create` only when absent before applying it. A concurrent creation is
accepted after a second lookup without overwriting existing label metadata. A
provisioning failure remains bounded to the label result, records its reason in
the babysitter event, and lets the separate give-up comment preserve the repair
outcome on the PR.
