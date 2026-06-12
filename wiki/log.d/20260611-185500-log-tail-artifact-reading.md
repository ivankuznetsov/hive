---
date: 2026-06-11
slug: log-tail-artifact-reading
pages: [commands/web]
---

Operator-reported: the log's 3s poll and the page's pushed morphs yanked
scroll/open state, making logs and artifacts unreadable mid-scroll. The log
frame is now data-turbo-permanent (morphs never touch it) and its poll
controller gained `tail -f` semantics: pinned to the pane's bottom while
following (data-following beacon), paused while scrolled up reading, resumes
at the bottom. Artifacts keep morphing (content stays live while agents
write) but a Stimulus controller snapshots the operator's details-open
choices before each morph and reapplies them after, keyed by artifact name
and scoped to morphs only so state never leaks across task pages. System
tests pin both: pause/resume with a real growing log file, and an
open-second-artifact surviving a broadcast-triggered morph with updated
content.
