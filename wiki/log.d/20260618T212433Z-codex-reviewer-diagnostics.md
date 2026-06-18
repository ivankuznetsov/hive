## reviewers — diagnose codex-native-review failures + reject prompt-template echo

**Action:** Closed the observability gap behind `reviewer all_failed` and stopped
hollow codex reviews from passing as clean.

**Problem:** When `codex review` failed, `CodexReview` recorded only the terse
`codex review exited with status=1` in `reviews/errors-NN.md` — codex's captured
combined stdout+stderr (where the actual cause lives) was discarded. A flaky
codex exit-1 was therefore undiagnosable (the #1378 case). Separately, codex
sometimes echoes the prompt's own example block (`- [ ] <finding>:
<one-line justification>` under each header); that passed the severity-header
check and was recorded as a hollow clean pass.

**Fix (`lib/hive/reviewers/codex_review.rb`):**
- On any reviewer failure, append the last `FAILURE_TAIL_BYTES = 2000` of the
  captured codex transcript to the `:error` message (scrubbed, indented under a
  labeled fence), so it lands in `errors-NN.md`. Bonus: because
  `Hive::AgentLimit.limit_reached?` only inspects the error message, a codex
  usage-limit that exits non-zero is now detectable and routes the phase to the
  cooldown `limits_reached` path instead of a generic `all_failed`.
- New `TEMPLATE_ECHO` guard: output carrying the literal
  `- [ ] <finding>: <one-line justification>` placeholder is rejected as a
  failure (retries) rather than recorded as a clean pass. A genuine
  `No findings.` review is unaffected. Validity now flows through a single
  `usable_review?` predicate; `failure_message` split into a terse `base_reason`
  + `captured_tail`, threaded through `error_result(detail:)`.

**Tests:** failure message carries the codex output tail; a usage-limit failure
is `AgentLimit.limit_reached?`-detectable; a template echo is rejected with
`echoed the prompt template`; a real `No findings.` review still passes. Updated
the transcript-dropping fixture to use a real finding instead of the placeholder
(it was incidental to that test's intent).

**Not fixed:** the codex-side *cause* of an intermittent exit-1 is still
codex's own — but it is now captured for diagnosis the next time it happens.
