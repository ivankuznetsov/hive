## Wiki

This project has an LLM-maintained knowledge base in `wiki/`.

- `wiki/` — project knowledge pages maintained by you (the LLM)
- `wiki/index.md` — catalog of all pages
- `wiki/log.md` — append-only changelog
- `wiki/gaps.md` — known gaps and open questions
- `raw/notes/` — manually added reference material

**Always check wiki/ before answering questions about this project's architecture, patterns, or decisions.**

When you learn something new about the project or make a decision:
1. Create or update the relevant page in wiki/
2. Update wiki/index.md if a new page was created
3. Append an entry to wiki/log.md

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
