## [2026-06-30T14:48:32Z] wiki — audit make-the-hive-daemon-automatically-260629-223d docs cleanup

**Action:** Refreshed the global project wiki after branch `make-the-hive-daemon-automatically-260629-223d` touched wiki pages and log fragments. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "adhoc review daemon auto retry diagnostic evidence"` returned no indexed hits, and the configured `main_wiki_path` (`/home/asterio/wikis/master/wiki`) was absent, so verification used direct source/wiki reads. Inspected the branch diff plus current `Hive::Commands::AdhocReview`, `Hive::Worktree.materialize_pr`, `Hive::Gh.pr_metadata`, `Hive::Pr.identifier_to_number`, daemon recoverable/stale healer code, `Hive::DiagnosticEvidence`, and focused tests.

The existing global wiki already preserved the ad-hoc PR review source mappings and daemon auto-retry coverage that the branch diff touched. Updated [[commands/status]] because it still described read-only `hive status --diagnose` as identical to status-row JSON; current code uses `Hive::DiagnosticEvidence` to synthesize diagnostics for non-red rows when on-disk evidence exists. Updated [[testing]] and [[gaps]] so `lib/hive/diagnostic_evidence.rb` and `test/unit/diagnostic_evidence_test.rb` are discoverable. Carried forward the live-evidence uncertainty in [[gaps]]: no new artifact was found proving a real daemon recoverable-error retry or a real registered-project ad-hoc PR review flow. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/status]]
- [[testing]]
- [[gaps]]
