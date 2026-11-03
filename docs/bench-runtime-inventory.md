# Benchmark runtime delivery inventory

Canonical prerequisite verified 2026-11-03: `ivankuznetsov/hive-bench`,
`origin/main` at `243ef7bb7e2cb3f6ecbe2d5fe3f3ab9c83cff326`. GitHub reports
an active, unarchived repository and push permission. Fresh checkout for this
execution: `tmp/canonical-hive-bench` inside the Hive execution worktree;
branch `fix/ranked-generation-evidence`. The operator's existing hive-bench
checkout was not inspected or edited.

Canonical instructions: `AGENTS.md`, `wiki/index.md`, `.llm-wiki/config.json`.
The configured cross-project main wiki is unavailable at its configured path.
The canonical Rakefile defines `bundle exec rake test` (individual files via
`TEST=test/name_test.rb`). Prerequisites: Ruby 3.4, Bundler, Gemfile.lock gems
including minitest, rake, sqlite3. `wiki/v3-workflow.md` also documents the
tracked `tmp/bench-workflow-smoke.sh`, requiring a source Hive checkout via
`HIVE_SRC`; its stage stubs must follow the provenance contract too. No paid
providers or containers are required for deterministic unit tests.

Canonical producers: `harness/run.rb`, `harness/lib/pipeline.rb`,
`harness/lib/hive_driver.rb`; adapters `harness/run_all.rb`,
`harness/hive_run.rb`, `harness/pipeline_run.rb`. Scoring and evidence readers:
`harness/score.rb`, `harness/merge_results.rb`, `harness/rejudge.rb`,
`harness/deliberate.rb`, `harness/lib/judge_provenance.rb`, and standalone
summary loops in the three driver commands. Tests exercise raw judge maps;
the smoke script also reads raw maps in its deliberate stub. Canonical has no
tracked site/assembly generator: `wiki/v3-workflow.md` explicitly records this.
README links the external hivecli.sh/bench site, whose source is outside these
accessible checkouts and is unavailable for this delivery. Historical RESULTS
pages and captures are not rewritten. Unknown external consumers retain access
to `judged`/`gated` keys but may ignore their narrowed schema-v2 semantics.

Hive packages counterparts under `templates/builtins/bench/runtime/harness/`.
Campaign consumers are `templates/builtins/bench/{generate,judge,publish}.md`,
including slate checks, deliberation union, and publish tables. Installation
uses `Hive::Workflows::Bench.install_runtime!` to snapshot packaged files; no
canonical checkout is needed at runtime, and editing the template does not
deploy into installed campaigns. There is no canonical sync script; changed
harness files are compared explicitly. Canonical's older driver/provider code
will be aligned for files changed by this work, with existing newer Hive
provider/quota behavior preserved. Exact synchronized files and verification
are recorded with the final delivery.
