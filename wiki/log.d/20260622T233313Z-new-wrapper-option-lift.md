---
date: 2026-06-22
slug: new-wrapper-option-lift
pages: [cli, commands/new, testing]
---

Fixed the `bin/hive` wrapper path for `hive new` so standalone allow-listed
options are lifted out of the task text no matter where they appear in argv.
The canonical workflow-authoring command now works as printed:
`hive new PROJECT --workflow ID "<your idea>"` pins the task workflow instead
of capturing `--workflow ID` into `idea.md`.

The allow-list is intentionally closed: `--workflow`, `--depends-on`, and JSON
booleans are lifted, including `--name=value` forms for the value-taking
options. Remaining positionals are rebuilt as `PROJECT -- TEXT...`, preserving
literal `--help`, unsupported `--json=...`, unrecognized `--foo`, explicit `--`
tails, and quoted strings that merely contain `--workflow`.

Added `test/integration/new_wrapper_argv_test.rb`, which drives the real
`bin/hive` subprocess against on-disk project workflows, plus refreshed the
older wrapper test that previously asserted the swallowed-`--workflow` bug.
Updated [[cli]], [[commands/new]], and [[testing]] to describe the new wrapper
contract.

Review follow-up: hardened the value-option branch so a trailing or value-less
`--workflow`/`--depends-on` no longer consumes the next token. The value is only
lifted when it exists and is not option-like; otherwise the bare option drops to
the literal-text tail, fixing the regression where `hive new proj idea --depends-on`
mis-bound PROJECT to the idea text. Added coverage for the trailing value-less
case, the `--depends-on=42` equals form, and a literal `--` tail, and refreshed
gap #29 in [[gaps]] to point at the lift-and-rebuild contract.
