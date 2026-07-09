## [2026-07-08T21:00:00Z] workflows - descriptor field scoping + council parity (review pass 2)

**Parser (`Hive::Workflows::DescriptorParser`):** Tightened field scoping so a
field set on a stage kind that never reads it fails at load rather than becoming
a silent no-op. `skill`/`instruction` are now rejected on `kind: council` (a
council reads its reviewers' instructions, not the stage's), and
`input`/`reviewers`/`council` are rejected on `kind: agent` (only the council
runner consumes them). `deliverable` is now allowed only on the last stage (the
terminal completion gate is the only reader). The `revise` + `max_rounds: 1`
load-time warning was extended to also cover `revise` under any non-`consensus`
`exit_rule` (the council loop only revises under `exit_rule: consensus`, which
defaults to `human`). Duplicate reviewer `output_basename` detection now compares
the SANITIZED basename (same `gsub` as `Council::Reviewer#output_path`), so
`a/b` vs `a-b` collisions are caught. `triage_output` is validated to stay inside
the stage folder (no leading `/`, no `..` segment) per R2.

**Council runner:** `Council::Reviewer#run!` clears any stale
`reviews/<name>-NN.md` before each attempt so a leftover file from a failed
attempt/interrupted run cannot satisfy the success check and count toward quorum.
The `AGENT_WORKING` marker now carries `pid`/`started` for parity with the agent
runner (`hive status` can show which runner owns an in-flight council).
Deterministic triage readiness (`Triage#ready?`) tolerates an optional leading
Markdown-heading prefix (`## Verdict: ready`). Reviewer verdict files remain in
`reviews/` regardless of a custom `triage_output` dir — documented as intentional
(review paths are passed explicitly, never globbed).

**Base:** `spawn_agent`'s "profile does not honor per-stage model/effort" note is
now gated on `profile.name != :claude`, so a claude caller supplying explicit
`cli_flags:` with `model`/`effort` no longer gets the misleading warning.
