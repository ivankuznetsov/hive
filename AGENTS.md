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

## Documented Solutions

`docs/solutions/` contains documented solutions to past problems (bugs, architecture patterns, workflow issues, and conventions), organized by category with YAML frontmatter such as `module`, `tags`, and `problem_type`. Relevant when implementing or debugging in documented areas.
