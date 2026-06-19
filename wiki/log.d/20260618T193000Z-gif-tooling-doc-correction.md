---
date: 2026-06-18
slug: gif-tooling-doc-correction
pages: [commands/web, dependencies]
---

Corrected a factually-wrong claim that the hivebox Docker image could produce
terminal GIFs. The image ships `asciinema` (records a `.cast`) and `ffmpeg`,
but no terminal-GIF encoder: `ffmpeg` cannot read an asciinema `.cast`, and
`agg`/`vhs` (the actual encoders — `agg` renders a `.cast`, `vhs` records
straight to GIF) are not installed. So an in-box TUI/CLI demo records a `.cast`
and then degrades to a `failed` capture unless the agent installs `agg`/`vhs`.
This degrades safely (artifacts U6 is plan-deferred/optional), so the fix was
documentation accuracy, not adding the encoders to the image.

Updated [[commands/web]] and [[dependencies]] plus `docs/visual-artifacts.md`
and `packaging/docker/README.md` to name the missing encoder; did not edit
compiled [[log]].
