## workflows - built-in content research workflow

**Action:** Added the built-in `:content` non-coding workflow descriptor and
registered it beside `:coding`. The descriptor uses an inert `inbox` stage for
`idea.md`, generic agent stages for research, outline, draft, critique, and a
terminal `done` agent that writes `article.md`.

**Tests:** Added descriptor-shape, per-stage generic-agent, and full daemon e2e
coverage for the content workflow. Updated registry and init prompt expectations
now that `content` is a built-in workflow choice.

**Docs:** Refreshed [[modules/workflows]] and [[testing]] to distinguish the
built-in `:content` workflow from the test-only `:content_fixture`.
