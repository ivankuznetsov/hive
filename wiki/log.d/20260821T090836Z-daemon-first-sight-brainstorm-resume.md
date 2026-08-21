# Daemon resumes fully answered brainstorms on first sight

The daemon now distinguishes a non-empty, fully answered coding brainstorm
from both the agent's unanswered `WAITING` output and an unknown or malformed
state file. Once the ordinary edit debounce has elapsed, a completed Q&A can
dispatch even when no prior `(project, slug)` mtime baseline exists.

Previously, if every answer landed before the daemon first observed the row —
for example while the daemon was stopped — first-sight handling recorded the
already-answered file mtime as its baseline. Every later tick saw an unchanged
mtime and skipped forever, requiring another edit or `touch`. Pending answers
still hold, fresh writes still debounce, and empty or unparseable documents
still take the conservative generic baseline path.

For tasks already stranded before this fix, baselines restored from disk stay
distinguishable until the current daemon observes or dispatches them. A fully
answered brainstorm gets one restart recovery attempt; the resulting dispatch
consumes that provenance so later ticks keep the normal duplicate-run brake.
