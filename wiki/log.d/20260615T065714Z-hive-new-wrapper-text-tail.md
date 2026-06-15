---
date: 2026-06-15
slug: hive-new-wrapper-text-tail
pages: [cli, commands, commands/new, testing, gaps, index]
---

Refreshed command/API and executable-entrypoint wiki coverage after PR #478
fixed `bin/hive` so `hive new PROJECT TEXT...` treats flag-looking
tokens after `PROJECT` as task text instead of wrapper controls. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "wrapper
new task text control flags cli json boolean patrol hive new"` surfaced the
existing wrapper/gaps coverage, and the configured master wiki path had no
project-specific match.

Inspected the committed diff plus current `bin/hive`, `lib/hive/cli.rb`,
`lib/hive/commands/new.rb`, `test/integration/cli_version_test.rb`, [[cli]],
[[commands]], [[commands/new]], [[testing]], and [[gaps]]. Documented the new
`hive new` text-tail boundary: after the registered project argument, `--help`,
`-h`, and malformed-looking `--json=...` tokens remain literal idea text, while
wrapper options before that boundary keep the existing help/JSON validation
behavior. The focused checkout test now proves `hive new PROJECT add --help
docs` and `hive new PROJECT literal --json=yes text` create captured ideas
instead of rendering help or rejecting malformed JSON. Carried forward the
remaining packaging uncertainty: no in-tree artifact proves the RubyGems,
Homebrew, or AUR installed `hive` executable exercises the same wrapper path.

Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.
