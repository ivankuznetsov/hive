---
title: Keep quiescence failure paths structured
type: log
created: 2026-09-26
tags: [daemon, quiescence, babysitter, testing]
---

- Registered the babysitter's `admission_check_failed` event so persistent
  runtime-admission errors are logged and fail closed instead of raising from
  the logger's event allowlist.
- Corrected quiescence status failure coverage to call the implemented private
  status builder and fixed the coverage-gap test's Omakase formatting.
