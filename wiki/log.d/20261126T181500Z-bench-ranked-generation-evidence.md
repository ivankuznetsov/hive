# Rank only current successful benchmark evidence

Packaged benchmark harness writers now emit `hive-bench-results` schema version
2, narrowing retained `judged` and `gated` aggregates to eligible executions
(`generated` and `empty_diff`) with current, verified bindings while preserving
raw scores, failure statuses, unknown statuses, and operational costs under
`diagnostics`, `generation`, and `efficiency`.

- **Attempt provenance and recovery**: `Run`, `Pipeline`, and `HiveDriver`
  persist `generation-attempt.json` outside candidate checkouts, rotating
  `generation_id` on identical-byte regeneration and on execute/review resume.
  Verified completed-artifact recovery retains attempt identity and finalized
  per-attempt delta telemetry without clobbering it with cumulative log totals.
  `RunAll` rescue preserves `artifact_verification_error`, honors ungated
  `"judged"` subsets, and never stamps a prior attempt's manifest onto
  pre-`start!` failures.
- **Evidence binding and backfill**: Judge `evidence_binding` binds to
  `generation_id`, `artifact_binding`, and `evaluation_context` (with
  `RunAll`/`HiveRun`/`PipelineDriver` honoring `--plan-source` and
  `generate.md` passing `--plan-source candidate` to match `judge.md`
  `rejudge.rb --only-missing`). Objective gates bind only to `generation_id` and
  `artifact_binding`, so rejudging under a changed plan source or reference mode
  preserves valid current-generation gates. `rejudge.rb` reconciles finalized
  manifest `run_status`/telemetry for legacy adoption, rejects identified
  `run_status` conflicts, ignores 0-byte timeout execute patches, and matches
  `RunAll#park`'s attempt digest shape without collapsing distinct `nil`-ID
  legacy failures.
- **Merge, campaign handoff, and deliberation**: `merge_results.rb` enforces
  explicit oldest-to-newest snapshot precedence, keeps single/repeated
  diagnostic `judge_only` cells visible without ranking them, and archives
  discarded snapshots in `generation_history`. `CampaignMerge` retains
  parked-only `limit_hit`/crash snapshots while skipping retired per-cell
  generations. `deliberate.rb` filters on admitted eligible judges, and
  `judge.md` summarizes only current eligible generations in
  `deliberation.json`.
