## [2026-07-02T01:16:26+01:00] wiki — refresh HEAD llm-wiki bootstrap coverage

**Action:** Refreshed planning/documentation coverage after branch `HEAD`
committed the managed llm-wiki bootstrap update. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first; `qmd search "digest cli mode command API dry run"` had
no indexed hits for the worktree slug, so verification switched to the actual
commit surface and searched wiki/main-wiki context for llm-wiki bootstrap,
refresh-script, `main_wiki_path`, and QMD behavior. Inspected the committed diff
plus current `Hive::LlmWikiBootstrap`, generated script/context sources, and
focused init coverage.

Documented that the generated refresh script now resolves QMD through
`HIVE_QMD_BIN`, PATH, Hive's managed QMD install, and install-prefix fallback;
keeps nested QMD/Codex calls free of Git hook-local environment; and reports
missing/failing/timed-out QMD as stale-index warnings/no-ops rather than
aborting the Codex refresh. Also recorded the normalized managed LLM WIKI block
and `created_by: "hive"` bootstrap ownership. Did not run `qmd update` or
`qmd embed`.

**Refreshed pages:**
- [[commands/init]]
- [[modules/git_ops]]
- [[gaps]]
