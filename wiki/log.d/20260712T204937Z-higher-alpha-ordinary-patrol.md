# 2026-07-12 — Higher-alpha ordinary patrol

- Audited every patrol-titled GitHub PR created from 2026-05-12 through
  2026-07-12. Of 218 generated `Hive patrol:` findings, 144 merged, 65 closed
  unmerged, and 9 remained open. All 218 originated from only nine legacy
  slices; seven command/test slices produced 211. In June 1–20, 48 of 53
  closed findings were explicitly duplicate, redundant, or superseded, and
  model-authored severity/confidence did not predict novelty or delivery.
- Replaced ordinary patrol's overlapping route/package/monolithic-test mapping
  with the language-neutral component/import mapper plus separate public
  command slices. Generic text source and unfamiliar languages under common
  code roots remain first-class; subsystem tests attach to their component
  instead of forming one broad provenance bucket.
- Tightened discovery to evidence-backed production defects. New findings
  carry contract, impact, scope, root cause, reproduction, and targeted
  validation; evidence must be a confined regular repository file and the
  primary trigger/root cause must belong to the mapped slice. The prompt
  prefers zero findings and routes documentation, test-gap, and
  maintainability work away from ordinary auto-fixing.
- Added deterministic 0–100 alpha scoring and a globally ranked candidate
  portfolio. Semantic same-run/historical duplicates, active-feature overlap,
  low-value categories/scores, and excess findings from one feature are
  suppressed before fixer work. Structured fingerprints no longer depend on
  volatile feature attribution, while legacy records retain their v1 fallback.
  Severity and confidence are gates/small tie-breakers rather than dominant
  weights because those model-authored labels did not predict corpus delivery.
- Changed the fix contract from the smallest code change to the smallest
  complete root-cause repair. The fixer starts from freshly fetched default
  branch state, declares bounded regression/audit paths, and receives a
  machine-observed before/after receipt; stale, false, or proof-less findings fail closed without
  publication. PR/review handoffs preserve the alpha, contract, impact, root
  cause, reproduction, and validation context.
- Command entrypoints remain supporting context in architecture components but
  are primary evidence anchors only in their dedicated command slice. Manifest
  scripts are grouped into one contract review, preventing repeated agent calls
  over identical owned files. Fix proofs are bounded to 64 KiB, and a separate
  six-attempt cycle cap limits fixer cost when candidates are stale or fail.
- Finding ids now include their unique review occurrence instead of overwriting
  the prior run, and each cycle writes an immutable selection audit with scores
  and skip reasons. Defaults are three findings per feature, alpha gate 70,
  one automatic fix per feature per cycle, six fixer attempts, and three opened
  PRs per cycle.
- Bounded review cost with a deterministic 12-feature rotating batch. The
  exact detached SHA and cursor survive daemon cycles—even when default moves—
  and `last_scanned_sha` advances only after that complete map is covered.
  Reviewer output is capped, strict, atomically admitted, source-verified, and
  v2 exposes attempted/success counts plus exact partial-review errors.
- Made fix proof machine-owned: Hive runs the selected configured command on an
  isolated unpatched base with bounded agent-declared regression files overlaid
  and on the patched tree, requires a normal regression-identified failure then
  pass, applies the changed-path guardrail, and labels root-cause/audit prose as
  agent-reported. Fixer rejection no longer permanently resolves a finding.
- Bound publication to the validated commit: strict fresh fetch, exact base/head
  and clean-worktree checks, full title/body/exact-diff secret scanning, leased
  push, remote/PR reconciliation, and exact-patch reuse after handoff failure.
  Diff/ref/fetch failures block instead of falling back or publishing.
  Refreshed the two Brakeman argv-form false-positive fingerprints after the
  new exact-ref helpers moved those calls.
- Published the expanded ordinary-patrol response and durable finding record as
  `hive-patrol.v2` and `hive-patrol-finding.v2` while preserving both v1
  schemas. The response exposes review completeness/errors and closed per-attempt
  fix/publication outcomes with dynamic detail separated from reason codes.
