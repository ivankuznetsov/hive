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
## Wiki

This project has an LLM-maintained knowledge base in `wiki/`.

- `wiki/` — project knowledge pages maintained by the agent
- `wiki/index.md` — catalog of all pages
- `wiki/log.md` — compiled append-only changelog
- `wiki/log.d/` — per-change changelog fragments
- `wiki/gaps.md` — known gaps and open questions
- `raw/notes/` — manually added reference material

Always check `wiki/` before answering questions about this project's architecture, patterns, or decisions.

When you learn something new about the project or make a decision:
1. Create or update the relevant page in `wiki/`
2. Update `wiki/index.md` if a new page was created
3. Add a `wiki/log.d/<timestamp>-<slug>.md` fragment; do not edit compiled `wiki/log.md` directly in feature PRs

Never hallucinate. Ground everything in code or existing wiki pages. If unsure, note it in `wiki/gaps.md`.

Use `[[page-name]]` backlinks between wiki pages.

Query protocol:
1. Read `.llm-wiki/config.json` when it exists.
2. Run `qmd search "<topic>"` when QMD is available. Use `qmd query "<topic>"` only when local model generation is acceptable; if it hangs or errors, fall back to `qmd search` or `rg`.
3. Fall back to `rg "<topic>" wiki/`.
4. Check the configured `main_wiki_path` before making architectural decisions when it exists.
5. Also check default main cross-project wiki paths when they exist:
   - `~/wikis/master/wiki/`
   - `~/wikis/main/wiki/`
   - `<parent-of-project>/wikis/master/wiki/`
   - `<parent-of-project>/wikis/main/wiki/`
<!-- END LLM WIKI -->
