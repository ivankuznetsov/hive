---
title: Keep hyphenated review lenses and rediscover the QMD main wiki
type: fix
source: lib/hive/plan_review/result_parser.rb, templates/plan_review_*.md.erb, lib/hive/llm_wiki_bootstrap.rb
created: 2026-08-28
---

**Action:** Fixed two fail-closed contract mismatches found during Screenote
dogfood. Plan-review results now accept lowercase specialist-lens names using
hyphens or underscores, and every review prompt publishes that exact grammar,
so a valid Grok review using names such as `product-lens` retains its findings
and coverage instead of becoming a misleading terminal failure. Existing
blocked records carrying the exact legacy diagnostic become runnable and get
one versioned automatic retry per affected initial reviewer role, while
current-contract malformed output remains terminal. New route receipts retain
diagnostic provenance so reviewer-authored text cannot impersonate a parser
migration failure. LLM-wiki
bootstrap now resolves the `hive-wiki` QMD collection before legacy main-wiki
paths, allowing a stale deleted `main_wiki_path` to migrate to the live Hive
wiki while preserving an existing valid custom path. Malformed, unreadable,
or structurally incompatible optional QMD configuration falls back safely.
Focused parser, adapter, orchestrator, and bootstrap regressions cover both
production failures and their bounded recovery paths.
