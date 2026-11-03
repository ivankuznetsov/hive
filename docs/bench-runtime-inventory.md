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

## Runtime parity

Changed-file comparison covers every canonical harness path changed from the
prerequisite revision. These 21 files match the packaged counterparts byte for
byte:

- `deliberate.rb`
- `hive_run.rb`
- `lib/campaign_contract.rb`
- `lib/campaign_merge.rb`
- `lib/claude_judge.rb`
- `lib/codex_judge.rb`
- `lib/deliberation.rb`
- `lib/generation_provenance.rb`
- `lib/hive_driver.rb`
- `lib/judge_provenance.rb`
- `lib/judge_slate.rb`
- `lib/openrouter_judge.rb`
- `lib/pipeline.rb`
- `lib/result_evidence.rb`
- `lib/reuse.rb`
- `merge_results.rb`
- `pipeline_run.rb`
- `rejudge.rb`
- `run.rb`
- `run_all.rb`
- `score.rb`

The only intentional changed-file difference is `lib/agent_limit.rb`: canonical
retains its pre-existing UTC reset-hint `retry_after` helper and classification
patterns, while Hive retains its own existing pattern set. Both define the same
typed `ProviderLimitError`. This preserves each runtime's provider-quota retry
policy. Canonical's provider adapters and CLI dependencies were aligned with
Hive's maintained typed-failure and explicit routing support; their defaults are
unchanged. The shared evidence predicates, attempt manifests, merge, backfill,
slate checks and summaries are identical.

Installation verification executes the deterministic generation/backfill/merge
lifecycle against a newly installed runtime with no canonical source dependency.
The fixture uses disposable local Git repositories and fake provider CLI output;
no paid provider or container is invoked.

## Deterministic regression proof

| Contract | Regression evidence |
| --- | --- |
| Eligible-only ranking, nil metrics, failure costs and current coverage | `score_test.rb` (canonical `result_evidence_test.rb`) |
| Identity rotation, recovery/promotion, resume and planner failure | `generation_provenance_test.rb`, `hive_driver_test.rb`, `pipeline_test.rb` |
| Ordered snapshots, stale overlays, conflicts, legacy adoption and idempotence | `merge_results_test.rb`, `rejudge_test.rb` and ordered CLI subprocess fixtures |
| Configured slate, quota routing, current deliberation and publication | `consumers_test.rb`, executable sections in `test/unit/workflows/bench_test.rb` |
| Generation through backfill and repeated publication in either runtime | Shared `bench_evidence_lifecycle.rb`, `lifecycle_test.rb` and `bench_workflow_install_test.rb` |

Hive harness tests live under `test/unit/bench_harness/`; canonical mirrors live
under `test/` (generation-specific merge/rejudge files have a `generation_`
prefix). No full coverage gate or autonomous review pass was run by execute.

## Focused verification

- Packaged harness, workflow and installation invocation: 105 tests, 835
  assertions, no failures or errors.
- Canonical documented `bundle exec rake test`: 380 tests, 1,502 assertions,
  no failures or errors.
- All eight Hive harness test files pass independently, including the final
  legacy bucket regression.
- Changed Hive test/support RuboCop check: no offenses.
- Canonical `tmp/bench-workflow-smoke.sh` with this Hive source: passed through
  generation, judge retry, merge and publication. Its fixture now uses an
  isolated initialized control plane, registered project, deterministic network
  metadata and generation-bound score/transcript stubs.

## Broad checkpoint limitation

`bin/test --all` completed its two isolated workers and component job: 15,960
tests, 305,435 assertions, 3 failures, 23 errors and 14 skips. It is not green.
All 23 errors and two failures report the same host procfs
`Errno::ESRCH` while reading `/proc/2606562/environ`, through the unchanged
`lib/hive/invocation_process_custody.rb`. The isolated OpenCode integration
rerun also reports that error (two tests, two errors). Both the custody source
and OpenCode integration file are unchanged from execution base `966211001e`.

The remaining failure is the whole-repository read-only command-index guard
during concurrent workspace activity; its isolated rerun passes (two tests,
52 assertions). Benchmark-scoped verification is green, but this delivery does
not claim a passing broad suite or change process-custody behavior outside its
scope. The normal CI-only merge gates and exhaustive coverage were not run.

## Paired delivery

Canonical branch `fix/ranked-generation-evidence` is published at
`10645abfac523abbda0681d5fb4ec862eac33ba6`:
https://github.com/ivankuznetsov/hive-bench/commit/10645abfac523abbda0681d5fb4ec862eac33ba6

Its unit commits are `a068be1` (eligibility), `f161543` (attempt identity),
`09fec57` (merge/backfill), `f1f0526` (campaign consumers) and `10645ab`
(documentation and verification). No canonical PR or Hive review pass was run
by execute. Hive's matching unit commits are recorded in this branch history.
