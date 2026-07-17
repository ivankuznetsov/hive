---
date: 2026-07-16
slug: babysitter-gh-api-option-values
pages: [commands/babysit, modules/babysitter]
---

The shared pflag-compatible scanner in `bin/hive-babysitter-stub-gh.rb`
consumes all separate values for known value-taking `gh api` options before
deriving method and payload state. This fragment adds a focused regression for
the security boundary: a `-XGET` value belonging to header, jq, preview, or
template is data, so a following scalar field remains an implicit POST and is
skipped instead of reaching the authenticated real `gh` binary.

`test/unit/babysitter/dry_run_env_test.rb` now covers both long and short forms
of those four options with a GraphQL mutation and a recording fake `gh` binary.
