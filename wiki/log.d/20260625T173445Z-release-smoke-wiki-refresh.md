---
timestamp: 2026-06-25T17:34:45Z
slug: release-smoke-wiki-refresh
tags: [wiki, release, hivebox, dependencies]
---

## [2026-06-25T17:34:45Z] wiki — refresh v0.3.1 release smoke and dependency coverage

**Action:** Refreshed the LLM wiki after reading `.llm-wiki/config.json`,
`AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]], recent compiled [[log]]
entries, and current `wiki/log.d` fragments first. `qmd search "hive workflow
screenote worktree review suppression release arm64 image smoke"` surfaced
current project wiki coverage in [[gaps]], [[testing]], and [[commands/web]].
Searched the configured main wiki path `/home/asterio/wikis/master/wiki`
before changing project pages; the other default cross-project paths did not
exist in this checkout. The master wiki had general Screenote/MCP/OAuth context
but no Hive-specific release-smoke guidance for the current changes.

Inspected recent history through `54fd3455`, including the v0.3.1 release prep,
RuboCop 1.88 dependency bump, root Brakeman/concurrent-ruby lock bumps,
Screenote OAuth/MCP merge, no-fix review suppression, dependency-stacking
worktree fix, workflow-selection/custom workflow commits, and the release
workflow change from macOS/Colima to native arm64 Linux Docker. Updated
[[commands/web]] and [[testing]] so the hivebox image smoke contract names
`hivebox-smoke-arm64` on `ubuntu-24.04-arm` instead of the obsolete hosted
macOS/Colima check. Updated [[dependencies]] and [[operating]] for `0.3.1`,
root RuboCop `1.88`, root Brakeman `8.0.5`, root `concurrent-ruby` `1.3.7`, and
the fact that `web/Gemfile.lock` remains separately locked to Brakeman `8.0.4`
and `concurrent-ruby` `1.3.6`; refreshed [[active-areas]] and [[index]] for
descriptor-backed workflows and the current release surface; and recorded the
remaining release-channel/live-provider plus web-lock dependency uncertainty in
[[gaps]].

Page count stayed 84; [[index]] was updated for summary/date, not for a new
page. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.

**Refreshed pages:**
- [[active-areas]]
- [[commands/web]]
- [[dependencies]]
- [[gaps]]
- [[index]]
- [[operating]]
- [[testing]]
