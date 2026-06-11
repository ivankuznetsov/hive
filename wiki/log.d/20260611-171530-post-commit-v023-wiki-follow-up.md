## [2026-06-11T17:15:30Z] wiki - follow up v0.2.3 release/orphan-sweep coverage

**Action:** Refreshed wiki planning/documentation coverage after commit
`6b9f14bb` touched wiki release and Claude/tmux orphan-sweep pages. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and
recent [[log]] entries first; `qmd search "v0.2.3 release orphan sweep claude
tmux"` and `qmd search "dependencies Gemfile.lock hive-cli 0.2.3 release"`
returned no indexed hits, and the configured master wiki path had no matching
release/orphan-sweep context.

Inspected the committed diff plus source commits `ad9b6204` and `024b29b0`.
Checked `Gemfile`, `hive.gemspec`, `Gemfile.lock`, `lib/hive.rb`,
`CHANGELOG.md`, `README.md`, `install.md`, `lib/hive/claude_launcher.rb`, and
`test/unit/stages/brainstorm_tmux_sentinel_test.rb`. Confirmed the current
pages are source-synced on the v0.2.3 path-gem/version bump and on the
`pgrep` + per-PID `TERM` orphan sweep that skips matched `tmux` server
commands and logs killed/skipped rows. Removed stale May 25 active-history
wording from [[active-areas]], corrected [[operating]] so the install section
names the direct runtime gems now owned by `hive.gemspec`, and refined [[gaps]]
to make the two unresolved verification points explicitly span the 2026-06-11
refreshes. Page coverage did not change, so [[index]] needed no structural
update. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.

**Refreshed pages:**
- [[active-areas]]
- [[operating]]
- [[gaps]]
