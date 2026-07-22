# Refresh current-main wiki coverage

- Read the managed-wiki configuration and repository guidance, then searched the configured main-wiki path and all four default cross-project locations. None of those directories exists in this checkout environment, so no external pages were available to merge.
- Audited the ten commits from the 2026-07-18 reconciliation (`cd57b54e6`) through local `v0.6.4` / `4e3e0d511`, including the changed workflow, web, patrol, service, release, lockfile, template, and test sources.
- Refreshed `active-areas.md`, `dependencies.md`, `templates.md`, and `index.md` for managed Honeycomb packages, the complete local operator UI, current patrol behavior, shared internals, current dependency locks, and the expanded template/runtime catalogue. Page coverage remains 93 pages, so the index list did not change.
- Updated `gaps.md` to close the current-checkout index-health blocker and stale provider-limit test-visibility concern, narrow the bench uncertainty to public-package/live-campaign evidence, and move release-source tracking to the local v0.6.4 tag without treating local tags as proof of public publication.
- Added this fragment without editing compiled `wiki/log.md`. Bounded QMD maintenance remains the wrapper's responsibility; this refresh did not run `qmd update` or `qmd embed`.
