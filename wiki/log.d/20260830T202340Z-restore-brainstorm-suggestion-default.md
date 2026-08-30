---
title: Restore repository-aware suggestion default
type: fix
source: lib/hive/config.rb
created: 2026-08-30
tags: [brainstorm, suggestions, config, ci]
---

Restored the enabled-by-default repository-aware brainstorm suggestion route.
Empty project configuration once again reaches the shared loading projection
documented by [[stages/brainstorm]] and [[commands/answer]], while an explicit
`brainstorm.suggestions.enabled: false` remains available after cleanup.
