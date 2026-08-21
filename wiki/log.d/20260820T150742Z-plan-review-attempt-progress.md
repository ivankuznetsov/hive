# Bind plan-review attempts to review progress

Durable `plan-review-run` attempt generation now includes the byte-exact
`plan-review/current.json` projection in addition to the ordinary task artifact
and dependency token. An unchanged review state still deduplicates against its
successful terminal attempt, but a revision, verification, or recovery-reset
transition creates a new generation that the daemon can admit autonomously.

Previously a successful orchestration step remained the semantic owner while
`plan.md` stayed unchanged. Later review transitions therefore replayed that
old terminal receipt forever, even when the projection explicitly requested
another verification attempt. The daemon appeared healthy but could not
advance the review without an operator bypass. A regression test now pins both
unchanged-state replay and changed-state admission.
