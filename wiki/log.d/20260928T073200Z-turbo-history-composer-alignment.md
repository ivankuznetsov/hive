---
date: 2026-09-28
slug: turbo-history-composer-alignment
pages: [commands/web, testing, gaps]
---

The project-filter controller now aligns the Turbo-permanent composer with the
filtered URL after Turbo completes a history restoration, in addition to the
immediate `popstate` alignment. The existing Playwright pipeline-flow example
reproduced a race where either Back or Forward could retain the project from
the page being left; the focused test was rerun after the correction. Hosted
system-test confirmation remains recorded in [[gaps]].
