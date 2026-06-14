---
date: 2026-06-14
slug: verify-release-jq-audit
pages: [active-areas, testing, gaps]
---

Refreshed wiki planning/documentation coverage after commit `aa160a2c`
(`ci: harden verify-release jq setup`) touched
`.github/workflows/install-smoke.yml`, [[testing]], and the existing
`verify-release-jq-provisioning` wiki fragment. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first; the qmd search for wiki refresh and post-commit
documentation coverage surfaced prior Hive post-commit refresh patterns, and
the configured master wiki path had no matching project guidance.

Inspected the committed diff plus current `.github/workflows/install-smoke.yml`,
`packaging/verify-release.sh`, [[testing]], and release/install wiki mentions.
Confirmed [[testing]] covers the new CI provisioning contract: the
`verify-release.sh (end-to-end behavior)` job uses runner-provided `jq` when
present, falls back to apt only when missing, and disables transiently broken
`packages.microsoft.com` apt source files before retrying the fallback update.
Refreshed [[active-areas]] for the current HEAD and [[testing]] metadata/TLDR
so install-smoke/release-verify coverage is represented in the page summary.
Updated [[gaps]] to distinguish the now-passed hosted PR #474 verifier rerun
(`27500473396` at `aa160a2c`) from the separate v0.3.0 published-artifact
verification gap, which remains open. Page coverage did not change, so
[[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.
