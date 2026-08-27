# Patrol Fix semantic completion is a valid daemon event

**Action:** Added `patrol_fix_semantic_completion` to the daemon logger's closed
event enum and widened the source-parity regression to recognize literal event
calls split across lines.

**Why:** Reaping a completed Patrol Fix semantic-decision child emitted this
event from a multiline call. The logger rejected the unlisted name and raised
`ArgumentError`, terminating the daemon and interrupting admission processing.

**Tests:** The logger regression failed on the previously invisible event before
the enum fix, then passed with the dispatcher and Patrol Fix admission scheduler
suites.
