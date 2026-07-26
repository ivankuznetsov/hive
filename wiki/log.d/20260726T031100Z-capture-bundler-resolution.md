---
date: 2026-07-26
title: Worktree capture resolves its locked Bundler without PATH shims
tags: [web, capture, worktree, bundler, reliability]
---

- `SourceBundle` reads the web lockfile's `BUNDLED WITH` version and resolves
  that exact Bundler executable through RubyGems.
- Capture no longer depends on a user-gem `bundle` shim being present on the
  daemon or agent PATH.
- A missing or malformed locked Bundler version fails before the private cache
  is populated.
