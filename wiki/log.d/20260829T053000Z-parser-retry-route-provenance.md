---
title: Preserve parser provenance for retryable review output
date: 2026-08-29
---

Malformed plan-review output is retryable, but it is still parser-authored
diagnostic evidence. `CeDocReview` now records `diagnostic_source: parser` on
that return path while retaining the runner's actual reviewer route, so the
durable recovery classifier can distinguish it from reviewer and runner text.
