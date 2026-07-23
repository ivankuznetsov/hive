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

## Documented Solutions

`docs/solutions/` contains documented solutions to past problems (bugs, architecture patterns, workflow issues, and conventions), organized by category with YAML frontmatter such as `module`, `tags`, and `problem_type`. Relevant when implementing or debugging in documented areas.

## Local Test Feedback Loop

- During implementation, run the smallest focused test files that cover the
  changed behavior. Do not run the full suite or coverage after every commit.
- Use `bundle exec rake test` as the broad local checkpoint when the change
  warrants it, normally once before handoff rather than once per commit.
- `bundle exec rake coverage` is the exhaustive CI coverage gate. Agents should
  run it locally only when changing coverage machinery or when explicitly
  requested.
- Packaged Hive web bootstrap and TUI reactivity scale are CI merge gates, not
  default local tests. Agents do not need to run them locally unless diagnosing
  their CI checks. The packaged-web task archives `HEAD:web`, so run it only
  after committing the relevant web changes.
