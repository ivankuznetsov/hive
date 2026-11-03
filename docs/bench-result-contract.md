# Benchmark result and generation evidence contract

Writers emit `schema: hive-bench-results` and `schema_version: 2`. The retained
`judged` and `gated` keys now describe admissible current-generation evidence.
Their permissive older meaning is not emitted alongside them. Version metadata
is informational: readers recompute admission for every record, including
mixed-vintage documents, and never trust stored summaries or eligibility flags.
Readers that ignore version metadata see silently narrower populations. The
external hivecli.sh/bench site and other sources outside the accessible
checkouts were unavailable; this delivery does not claim to update them.

## Execution eligibility and populations

Only `run_status: generated` and successful `empty_diff` are eligible executions.
Missing, unknown, `limit_hit`, `timed_out`, `agent_failed`, `plan_failed`, and
`execute_failed` statuses remain visible without becoming zero quality scores.
This does not change classification: the existing Hive outer-timeout exception
can classify rc=124 as `generated` when plan/develop reported ok and a nonempty
patch exists, even if review was truncated. Such a record remains eligible when
its evidence bindings validate. Eligibility promises the status allowlist, not
completion of every stage.

`cells` remains the attempted active-cell array. Each agent summary retains
`cells` as that array count. `coverage.attempted_cells` counts distinct task and
candidate keys across active cells and parked attempts; `coverage.attempts`
counts distinct identified attempts (legacy snapshots do not imply continuity).
`eligible_executions` counts current eligible cell keys, and `eligible_fraction`
divides those by attempted keys. Retired parked attempts cannot inflate it.
Zero eligible cells are always preliminary and unranked. Otherwise preliminary
means eligible coverage is below the minimum or incomplete across attempted
cells. A campaign stage may finish diagnostic generation while ranked coverage
is preliminary; preliminary labels alone do not change stage markers.

`judged.scored_cells` counts eligible active cells with at least one valid,
current-bound numeric judge score. `mean_quality` uses that evidence separately
for each judge, with `samples_by_judge` reporting its cell denominator.
`mean_quality_cross_family` also applies the existing candidate/judge family
filter. A successful empty patch is eligible but receives no invented judge
score. `gated.total` counts eligible cells with preserved `subset: gated` and a
valid current-bound pass/fail gate; `passed` is its numerator and `pass_rate`
is passed/total. No gate outcome or an empty eligible population yields an
unavailable rate, not zero. Judged/gated coverage is independent of execution
coverage and can be incomplete even when every execution is eligible.

Raw gates, judges, status and telemetry remain inspectable. Excluded partial or
unbound scores appear under `diagnostics`, apart from ranked aggregates.
`rejudging_needed` names the cell and its exclusion/recovery reasons.
`generation` contains operational status counts, including unknown statuses;
`operational_failures` separates parked attempts from pending/failed evaluations
whose execution status was eligible. Available cost/time for unsuccessful
attempts stays in total `efficiency`, deduplicated against active cells by known
attempt identity. Eligible and diagnostic efficiency are separate populations;
quality denominators must still be checked before computing cost per quality.
Measured wall time includes `fresh`, `pipeline`, and `hive`, while `reused`
output is a distinct provenance class without fresh execution time.

## Generation and evaluation provenance

Every new generation attempt mints an opaque `generation_id` before generation
starts and atomically persists `generation-attempt.json` at the output root,
outside the candidate checkout. Finalization binds patch and generated-plan
SHA256 digests to task/base, terminal status and available telemetry. An
identical-byte regeneration still has a new ID. Verified completed-artifact
recovery retains the ID. An interrupted attempt with an ID but no finalized
bindings recovers/promotes artifacts before finalizing under the retained ID
with state `recovery-finalized`; old evaluations do not gain authority thereby.
Resuming work that can change output rotates identity before the container runs.
The driver's exact configuration compatibility hash is separate and unchanged.

Each evaluation carries `evidence_binding` containing generation identity,
artifact binding and evaluated context. Context names the evaluated plan digest
and either a provided reference digest or explicit `reference_mode: withheld`.
An unavailable reference without explicit withholding is not valid context.
Patch equality, directory names and `mode: reused` never establish continuity.
Artifact resolution selects one verified patch/plan bundle; missing/ambiguous
bundles require recovery or selection and never masquerade as empty patches.

## Merge and backfill

`record_kind: generation` is an explicit generation snapshot;
`record_kind: judge_only` is an evaluation overlay. Standalone merge argv order
is oldest-to-newest for generation snapshots: the last explicitly supplied
snapshot replaces the whole active cell, including empty judges, gate and
telemetry. Timestamps and sorted filenames do not establish precedence.
Judge-only overlays can move before or after snapshots without choosing a
generation; stale overlays remain diagnostic. Proven same-generation,
same-context backfill unions successful judges and preserves original telemetry,
gates and subset. Matching IDs with inconsistent bindings are provenance
conflicts and cannot rank.

Discarded or ambiguous snapshots live in top-level `generation_history`, never
inside `cells`. Entries deduplicate by task, candidate, generation-or-null,
record-kind-or-legacy and SHA256 of canonical original-record JSON. Discard
reasons are separate from the digest. This history is inspection-only: its
costs are not added again to active-cell efficiency. Pending/failed buckets
remain separate, deduplicate by identified attempt and bucket, and retain
available telemetry. Absent legacy IDs do not imply continuity.

Campaign handoff supplies the root active snapshot first, explicitly new or
replacement generation snapshots next, and judge-only overlays last. It skips
per-cell generations already represented in root/history rather than replaying
a glob. Unchanged root backfill is paid evidence; a deliberate replacement
intentionally clears it. Deliberation uses generation/artifact/context keys for
transcripts, unions and skip checks, and never enters ranked quality.

Legacy results remain readable. Select the current artifact bundle and rejudge
without rerunning generation to establish durable provenance. Old evaluations
stay in history; fresh evaluations bind the selected artifact. An explicit
original-snapshot digest prevents charging an overlapping legacy parked record
again during adoption. Fresh judging cannot repair missing execution status or
restore an unbound gate: `fresh gating required` excludes that gate until a
fresh, bound gate run exists. Rejudge does not execute gates. Its document
rewrite preserves custom metadata, schema metadata, history and pending/failed
records while recomputing summaries. `--only-missing` checks verified current
bindings before skipping any paid judge.

Strict campaigns still reject unsuccessful execution before any judging spend.
The permissive default and provider quota/cooldown policy are unchanged. Optional
partial-patch judging is diagnostic; an ineligible materialized record follows
the manual missing-cell slate route rather than a retryable missing-judge route.

Hive installs a snapshot from `templates/builtins/bench/runtime/` through
`Hive::Workflows::Bench.install_runtime!`. The installed runtime needs no
canonical checkout. Source/template changes do not deploy into existing
campaigns. This change does not repair historical outputs, rerun paid providers,
or change Patrol. Publication recomputes Score output and renders unavailable
metrics and attempted/eligible/judged/gated coverage with separate diagnostics;
there is no reachable canonical site assembly script.
