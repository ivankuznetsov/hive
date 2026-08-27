---
title: Keep the pinned Codex judge runtime on its child PATH
date: 2026-08-25
tags: [bench, codex, mise, judge, recovery]
---

The packaged benchmark harness now prepends an absolute Codex judge
executable's own directory to PATH for that subprocess only. This lets the
pinned npm entrypoint resolve the sibling Node runtime even when Hive's narrow
agent environment would otherwise find an inactive mise shim. Global mise
configuration and the parent process environment remain unchanged.

The OpenRouter route regression records the child PATH and pins this scoped
resolution alongside the existing secret-free argv and provider-provenance
checks.
