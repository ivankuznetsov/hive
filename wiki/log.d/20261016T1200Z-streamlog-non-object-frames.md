---
title: StreamLog skips non-object and out-of-range frames
type: log
date: 2026-10-16
---

- `StreamLog.read` and strict sequence reconciliation now skip newline-terminated
  records that parse as non-object JSON (`"x"`, `null`, `[1]`, `42`) or carry an
  out-of-range sequence (`1e400`), instead of raising `NoMethodError` /
  `FloatDomainError` out of replay, construction, or every later append.
- Base64 padding-bit parity between reconciliation and `Base64.strict_decode64`
  is now pinned by an exhaustive final-quantum regression test.
