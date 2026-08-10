---
title: Sparse custody subprocess coverage
date: 2026-08-03
tags: [testing, coverage, capture, process-custody]
---

Coverage-instrumented custody children now flush their observed line and branch
hits before the production `exit!` boundary. Child result files omit untouched
sources, while the parent result retains the complete source inventory for the
100% line-coverage gate.
