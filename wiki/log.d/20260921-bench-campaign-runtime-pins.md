---
title: Honor registered benchmark runtime and runner image pins
date: 2026-09-21
---

Generation previously ignored campaign `runner_image` and `runtime_commit`, so
an OpenCode campaign selected its default image and the inherited dogfood runtime
instead of its registered bytes. The existing sealed preflight correctly rejected
that mismatch before candidate execution. Generation now validates explicit pins,
sets both harness image routes, verifies an optional Docker image ID and launches
that immutable ID, and selects source/bin/hive only when runtime_commit explicitly
matches source HEAD. Unpinned source remains a target checkout, not a controller
selection. Command-compiler regression coverage verifies inherited defaults cannot
override pins and mismatched commits/images fail before commands are emitted.
