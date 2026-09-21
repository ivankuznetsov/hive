---
title: Isolate the command-index no-write proof from coverage artifacts
date: 2026-09-02
tags: [cli, wiki, commands, testing, coverage]
---

The public-help and command-index integration proof now clears inherited Ruby
coverage instrumentation from its help subprocess. Coverage collection still
measures the integration test itself, while the child can no longer write an
ignored resultset file between the repository snapshots and falsely report a
mutation by the read-only command contract.
