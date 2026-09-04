---
title: Reuse validated runtime database connections
date: 2026-09-01
tags: [runtime-control-plane, attempts, performance]
---

Attempt repository construction now reuses an already validated runtime
control-plane connection. The first open and every reopen after disconnect or
fork retain full validation. A missing database path also forces full
validation so repository construction fails closed instead of continuing on
an unlinked SQLite inode. Explicit `Database#open!` continues to force
validation when a caller needs a fresh integrity decision.
