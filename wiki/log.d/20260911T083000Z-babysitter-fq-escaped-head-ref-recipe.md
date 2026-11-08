---
title: Fully qualify the untrusted PR head ref in the babysitter push recipe
date: 2026-09-11
---

The trusted `sh` recipe in `templates/babysitter_pr_fix_prompt.md.erb` now
interpolates the externally supplied PR `headRefName` as a fetch refspec
`Shellwords.escape("refs/heads/<ref>:refs/remotes/origin/<ref>")`, plus
`Shellwords.escape("refs/heads/<ref>")` (push) and
`Shellwords.escape("refs/remotes/origin/<ref>")` (remote-tracking rev-parse),
bound in `PrFixer#render_prompt`. Display-only lines keep the raw name.

Shell-escaping alone was insufficient: `git check-ref-format` accepts
leading-dash refs (`--upload-pack=false` makes an unqualified `git fetch`
parse an `--upload-pack` option and execute the named command locally) and
leading-`+` refs (`+topic` parses as a force refspec and fetches `topic`).
Fully qualified ref arguments cannot be option- or refspec-parsed, and the
escaped form keeps shell metacharacters literal.

Regressions render the prompt for `--upload-pack=false`, `+topic`, and
`review$(printf-owned)`, then execute the recipe's extracted `sh` block
against real fixture repositories with those literal branches and assert the
push lands on the fully qualified remote ref. A remote-move regression also
proves the second fetch refreshes the exact local tracking ref before the
expected-SHA comparison. See [[modules/babysitter]].
