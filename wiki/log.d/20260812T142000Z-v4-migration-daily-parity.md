## [2026-08-12T14:20:00Z] recovery — preserve daily accounting across v4 cutover resume

**Action:** Made recovery migration verify same-day admission accounting from
both bounded hot attempts and immutable permanent proofs, with a regression for
a terminal attempt already promoted before the v4 cutover resumes.

**Why:** Live migration retained the correct daily decision index but stopped
because its parity oracle considered only the hot scan and therefore treated
promoted same-day attempts as stale counters.
