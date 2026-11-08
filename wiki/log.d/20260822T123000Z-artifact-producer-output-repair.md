# Artifact producers can repair a valid capture descriptor once

Outcome-evidence producers now receive one bounded fresh-context repair when
their final descriptor fails controller admission. The repair prompt contains
the bounded validation error and previous output and tells the producer to
reuse successful controller-issued captures rather than repeat working browser
or terminal operations.

Inference and semantic review already had the same correction shape. Without
it, a harmless controller-owned field such as `rendering` discarded a valid
WebM and escalated a JSON formatting mistake into a whole daemon retry. The
admission block remains authoritative, and a second invalid result still fails
closed before the reviewer sees it.
