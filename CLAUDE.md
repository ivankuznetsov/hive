## Wiki

This project has an LLM-maintained knowledge base in `wiki/`.

- `wiki/` — project knowledge pages maintained by you (the LLM)
- `wiki/index.md` — catalog of all pages
- `wiki/log.md` — compiled append-only changelog
- `wiki/log.d/` — per-change changelog fragments
- `wiki/gaps.md` — known gaps and open questions
- `raw/notes/` — manually added reference material

**Always check wiki/ before answering questions about this project's architecture, patterns, or decisions.**

When you learn something new about the project or make a decision:
1. Create or update the relevant page in wiki/
2. Update wiki/index.md if a new page was created
3. Add a wiki/log.d/<timestamp>-<slug>.md fragment; do not edit compiled wiki/log.md directly in feature PRs

Never hallucinate. Ground everything in code or existing wiki pages. If unsure, note it in wiki/gaps.md.

Use [[page-name]] backlinks between wiki pages.

### Query Protocol
When you need project context:
1. Run `qmd search "<topic>"` (or `rg "<topic>" wiki/` if QMD unavailable).
2. Read relevant wiki pages.
3. File any new answers back to wiki/.

### Tags
#model #controller #auth #performance #debt #decision #architecture

### Cross-Project Context
Before making architectural decisions, check ~/wikis/master/wiki/ for existing patterns and known gotchas.

## Documented Solutions

`docs/solutions/` — documented solutions to past problems (bugs, architecture patterns, conventions, workflow learnings), organized by category with YAML frontmatter (`module`, `tags`, `problem_type`). Relevant when implementing or debugging in documented areas.

## Workflow

All new feature, bugfix, or refactor work must start in an isolated git worktree (use the `Agent` tool with `isolation: "worktree"` for delegated tasks, or `git worktree add` for direct work). Never mutate the main checkout for non-trivial changes — the worktree keeps the main branch clean and lets parallel work proceed without conflicts.

<!-- BEGIN LLM WIKI -->
## LLM Wiki

This project has a managed LLM wiki. Treat it as required project context.

- Project wiki: `wiki/`
- Index: `wiki/index.md`
- Change log: `wiki/log.md` compiled from `wiki/log.d/*.md`
- Known gaps: `wiki/gaps.md`
- Raw notes: `raw/notes/`

Before planning, implementation, review, or debugging:

1. Read `wiki/index.md`.
2. Search the project wiki with `qmd search "<topic>"` when QMD is available, or `rg "<topic>" wiki/` otherwise.
3. Use `qmd query "<topic>"` only when local model generation is acceptable; if it hangs or errors, fall back to `qmd search` or `rg`.
4. If `.llm-wiki/config.json` has `main_wiki_path`, search that main wiki too.
5. Use `/llm-wiki:wiki-plan` for planning-stage work when available.

When code behavior, architecture, commands, or dependencies change:

1. Update affected wiki pages.
2. Add a new `wiki/log.d/<timestamp>-<slug>.md` fragment; do not edit compiled `wiki/log.md` directly in feature PRs.
3. Record uncertainty in `wiki/gaps.md`.

Headless wiki refresh is managed by `.llm-wiki/refresh-wiki.sh` and
`.llm-wiki/post-commit-refresh.sh`. Codex is the configured headless wiki agent.
<!-- END LLM WIKI -->
