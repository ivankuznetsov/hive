---
title: Make compact status independent of require order
date: 2026-09-06
tags: [status, runtime-control-plane, ci]
---

Compact running status now requires the task-lease repository before deriving
its maximum lock payload size. Direct CLI invocations and isolated coverage
shards therefore load `Hive::RunningStatus` without relying on incidental
repository initialization by another test or command.
