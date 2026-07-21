---
title: Move repository admission into a Rails model
date: 2026-07-20
tags: [web, rails, architecture, repositories]
---

Hive Web now models an incoming checkout as `Repository`. The model owns the
GitHub source allowlist, safe local name/path, target ownership, bounded
process-group clone, partial-clone cleanup, and GitHub SSH-to-HTTPS origin
normalization before delegating initialization to `Project#setup!`.

`ReposController` is now request orchestration over `Repository`, `Project`,
`InitSetup`, and `GithubApi` instead of implementing process and filesystem
behavior itself. Target hardening also now rejects symlinks explicitly,
including symlinks to directories and dangling links, before setup can escape
the configured repositories root; focused model coverage pins that boundary.
