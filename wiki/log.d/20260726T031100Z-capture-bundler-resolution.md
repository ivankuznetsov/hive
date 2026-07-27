---
date: 2026-07-26
title: Worktree capture resolves its locked Bundler without PATH shims
tags: [web, capture, worktree, bundler, reliability]
---

- `SourceBundle` reads the web lockfile's `BUNDLED WITH` version and resolves
  that exact Bundler executable through RubyGems.
- Capture no longer depends on a user-gem `bundle` shim being present on the
  daemon or agent PATH.
- Bundle installation, Rails bootstrap/server, and fixture CLI setup all use
  that same resolved executable inside the deny-default runtime.
- The server thread owns the readiness writer until exit, and boot failures
  retain a bounded, redacted server-log diagnostic.
- Generated workflow marker comments are removed before explicit visual-proof
  intent classification, preventing `browser=skipped` from requiring capture.
- A missing or malformed locked Bundler version fails before the private cache
  is populated.
