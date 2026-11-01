## Proposal usage envelopes validate against their selected schema

**Action:** Added `usage` to the shared closed proposal error vocabulary and
the list, show, and mutation JSON schemas. Pre-dispatch argument failures now
validate against the proposal schema selected by the requested subcommand,
while command-level validation continues to use `invalid`.

**Verification:** Focused proposal CLI usage-envelope integration coverage and
the proposal schema vocabulary unit test.
