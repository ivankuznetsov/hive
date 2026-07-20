---
title: Architecture patrol issues and merge-driven launch capacity
date: 2026-07-20
---

- Made deduplicated GitHub issues the default review surface for architecture
  patrol while keeping automatic fixes independently disabled.
- Routed accepted theses without an auto-fix action to a pending-approval issue
  instead of completing with JSON-only output.
- Removed the ordinary daily agent-launch count from post-merge architecture
  stages and split durable ordinary/architecture accounting so merge volume
  cannot consume ordinary patrol's quota. Shared daily tokens, multiplied
  per-cycle launches, per-agent tokens, the full-lifetime launch lock, and the
  native budget guard remain enforced.
- Added a configurable 96/day architecture-only backstop for providers that
  repeatedly omit token accounting, with next-UTC-day scheduler backoff.
- Updated fresh-init disclosure: choosing architecture discovery also writes
  GitHub issue output on, while automatic code changes remain off.
- Added regression coverage for issue actionability, issue content/routing, init
  defaults, and architecture launches after ordinary daily capacity is spent.
- Dogfooded the exact-source path without a dry run: replaying merged PR 785
  completed 13 architecture reviews while the ordinary launch count remained
  zero, then filed the two accepted theses as GitHub issues 811 and 812.
- Dogfooded ordinary patrol separately: it found a reachable bot logger crash,
  proved the regression failed on the base and passed after the generated fix,
  opened pull request 814, and handed it to the standard 6-review flow.
