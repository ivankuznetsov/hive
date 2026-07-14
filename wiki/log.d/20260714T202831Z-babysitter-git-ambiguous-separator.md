---
date: 2026-07-14T20:28:31Z
slug: babysitter-git-ambiguous-separator
pages: [commands/babysit, modules/babysitter, testing]
---

## babysitter - fail closed on ambiguous Git separators

`bin/hive-babysitter-stub-git` now keeps scanning after a `--` that
immediately follows an unmodeled option. Real Git may consume that token as the
option's value rather than treat it as the pathspec separator; continuing the
safety scan prevents a later write or executable-affecting option from being
hidden. Unambiguous separators, including `git log -- -o`, still end scanning.

The real-Git regression in `test/unit/babysitter/dry_run_env_test.rb` proves
`git log --decorate-refs -- --output=PATH -1 HEAD` is skipped and cannot
create the requested output file.
