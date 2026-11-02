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

## Project-owned gap authoring

Authoritative gap text lives under `## Known gaps` on the owning domain page.
Read `wiki/gaps.md` first, find the owner, and update its narrative and the root
index in the same edit. Link other affected domains to that owner. Resolve an
item by retaining its verbatim evidence history under `### Resolved` and
removing its root entry when no open qualification remains.

The managed line “Known gaps: `wiki/gaps.md`” names the hand-maintained,
unresolved-only index. Recording uncertainty there means maintaining the index
alongside authoritative domain text; the index is not generated.

Entry grammar: `- [Title](relative/page.md#anchor)`

Example: `- [Task-journal growth and compaction](modules/events.md#task-journal-growth-and-compaction)`

Only entries in that form, plus blank separators, may appear under
`## Unresolved gaps`: no prose, summaries, or nested lists. Use one entry per
open logical gap in alphabetical display-title order, with destination
path/anchor as the tie-breaker. Link directly to a unique owner heading.

## Documented Solutions

`docs/solutions/` contains documented solutions to past problems (bugs, architecture patterns, workflow issues, and conventions), organized by category with YAML frontmatter such as `module`, `tags`, and `problem_type`. Relevant when implementing or debugging in documented areas.

## Local Test Feedback Loop

- During implementation, inspect `bin/test --changed --list`, then use
  `bin/test --changed` or the smallest explicit files via `bin/test`. Selection
  falls back visibly for shared/unmapped changes; inspect that before running.
  Do not run the full suite or coverage after every commit.
- Use `bin/test --all` (`bundle exec rake test:parallel`) as the broad local
  checkpoint when warranted, normally once before handoff. It uses two isolated
  workers and coordinates simultaneous agent runs. `HIVE_TEST_WORKERS=4` opts
  into four; `bundle exec rake test` remains the serial debugging fallback.
- Use `bundle exec rake coverage:changed` only for focused changed-lib coverage;
  test-only, component, and Rails changes use the general changed-test selector.
- `bundle exec rake coverage` is the exhaustive CI coverage gate. Agents should
  run it locally only when changing coverage machinery or when explicitly
  requested.
- Packaged Hive web bootstrap, TUI reactivity scale, multi-agent setup
  integration, operational status on read-only mounts, and the babysitter
  dry-run security matrix are CI merge gates,
  not default local tests. Agents do not need to run them locally unless
  diagnosing their CI checks. The packaged-web task archives `HEAD:web`, so run
  it only after committing the relevant web changes.
