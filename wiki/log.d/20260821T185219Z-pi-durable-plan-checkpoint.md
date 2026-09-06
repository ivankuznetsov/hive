# Pi plan retries retain useful progress

Hive now atomically seeds an empty or marker-only `plan.md` with the five
required sections before the planner starts. Existing plan and feedback bytes
are never replaced. The prompt requires the planner to refine that checkpoint
in place and write `<!-- WAITING -->` or `<!-- COMPLETE -->` only on the final
update.

This closes a failure reproduced while dogfooding Ox Alpha through Pi on a real
Webmail plan: the model completed substantial repository analysis and composed
a seventeen-unit plan in its response stream, but the upstream stream went idle
before Pi made its first write tool call. Three provider retries therefore left
no durable plan bytes for Hive's workflow retry to resume. A prompt-only first
fix reproduced the same multi-minute zero-byte window in live dogfood before it
eventually completed; making the initial checkpoint controller-owned removes
that first-write dependency even when the model later succeeds.

The checkpoint is provider-neutral and keeps the recovery boundary simple: Hive
continues to own retries, the terminal marker continues to own stage completion,
and a retried planner improves the useful partial document already on disk.

The same dogfood run exposed a second Pi boundary: Ox Alpha returned three
valid anchored findings, but used natural lowercase phrases in
`selected_lenses` and prose strings in `residual_evidence`. The old prompt did
not document either machine-only constraint, then the parser terminalized the
whole useful review. Primary/adversarial prompts now require snake_case lens
identifiers and an empty residual array, malformed producer output consumes a
bounded transient retry, and adapter-contract version 2 rekeys unchanged plans
so the fixed contract is exercised without operator intervention.
