---
date: 2026-06-11
slug: markers-stripped-from-markdown
pages: [commands/web]
---

Operator-requested: stage markers (`<!-- COMPLETE -->` and friends) no
longer show as literal text in rendered artifacts. `render_markdown` now
strips ALL HTML comments (plus the existing front-matter strip) before
rendering — matching how GitHub renders markdown, where comments are
invisible. The stage badge owns state display; prose should not repeat it.
