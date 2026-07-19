---
date: 2026-07-19
slug: workflow-scanner-negation-hardening
---

- Hardened Honeycomb workflow-package security scanning so a negation suppresses
  a restricted-behavior finding only when a recognized prohibition directly
  governs that match.
- Added fail-closed coverage for `do not forget` / `do not hesitate`, `never
  fail` / `never skip`, `not only`, `without exception`, and comma/semicolon
  clause transitions across exfiltration, shell, credential, and network
  behavior while retaining genuine prohibition documentation.
