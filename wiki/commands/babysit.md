---
title: hive babysit
type: command
source: lib/hive/cli.rb, lib/hive/commands/babysit.rb, bin/hive-babysitter-stub-git, bin/hive-babysitter-stub-gh
created: 2026-05-26
updated: 2026-06-13
For `gh api`, payload-bearing forms are treated as writes unless the command explicitly sets GET. Dry-run skips implicit-POST calls such as `gh api repos/owner/repo/issues/123/comments -f body=hi`, `-F body=@comment.md`, `--raw-field body=hi`, `--field body=hi`, and `--input payload.json`, while still passing explicit GET reads such as `gh api --method GET repos/owner/repo/issues -f state=open`. For `gh auth status`, the stub only passes non-token status checks: `--show-token`, `--show-token=...`, bare `-t`, and clustered boolean shorthand forms containing `t` before a value-taking `h` (for example `-at`, `-ta`, and `-ath`) are skipped and logged, while non-token reads such as plain `gh auth status`, `-a`, `-h github.com`, and `-hgithub.com` pass through.

The dry-run guard is best-effort: an agent that invokes absolute binary paths can bypass the PATH overlay. Use throwaway repos for destructive validation until a stronger sandbox exists. If `HIVE_BABYSITTER_REAL_GIT` is unset or points at an invalid binary, the stub exits 127 with a one-line diagnostic instead of guessing a system path.

## Tests

- `test/unit/commands/babysit_test.rb` covers CLI flag validation, lifecycle helpers, foreground `restart`, detached restart re-exec into `start --detach`, stale-runtime status recommendations, stale-runtime reload warnings, refused-stop failures, PID-file cleanup races, and bounded PID-lock behavior.
- `test/unit/babysitter/*_test.rb` covers interval parsing, dispatcher ticks, PR filtering, context building, PR fixing, GitHub ops, worktree materialization, and dry-run PATH wrappers, including the `gh api` implicit-POST payload flag guard, plain/non-token `gh auth status` passthrough with `--show-token`, bare `-t`, and clustered `-at` / `-ta` / `-ath` skips, git executable/write-option skips, plain `git remote show <remote>` skipping before configured transport helpers can run, subcommand `-p` passthrough, grep/`ls-files` read-option exceptions, grep pager `--open-files-in-pager` abbreviations and `-O` forms including clustered `-nO<cmd>`, value-taking grep short options such as `-eTODO` / `-fNEEDLEFILE.txt`, `--textconv` abbreviation and `cat-file --filters` skips, pathspec separator handling, env config/command seams such as `GIT_EXTERNAL_DIFF`, `GIT_SSH_COMMAND`, `GIT_SSH`, `GIT_PROXY_COMMAND`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT`, `GIT_CONFIG_GLOBAL`, and `GIT_CONFIG_SYSTEM`, plus HOME/XDG/local `.git/config` hardening for allowed git reads.
- `test/unit/babysitter/*_test.rb` covers interval parsing, dispatcher ticks, PR filtering, context building, PR fixing, GitHub ops, worktree materialization, and dry-run PATH wrappers, including the `gh api` implicit-POST payload flag guard, git executable/write-option skips, exact read-only `git branch` forms versus mixed branch mutation flags, subcommand `-p` passthrough, grep/`ls-files` read-option exceptions, grep pager `--open-files-in-pager` abbreviations and `-O` forms including clustered `-nO<cmd>`, value-taking grep short options such as `-eTODO` / `-fNEEDLEFILE.txt`, `--textconv` abbreviation and `cat-file --filters` skips, pathspec separator handling, env config/command seams such as `GIT_EXTERNAL_DIFF`, `GIT_SSH_COMMAND`, `GIT_SSH`, `GIT_PROXY_COMMAND`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT`, `GIT_CONFIG_GLOBAL`, and `GIT_CONFIG_SYSTEM`, plus HOME/XDG/local `.git/config` hardening for allowed git reads.
- `test/babysitter/run.rb` runs the acceptance smoke suite for early-green, ignored-label, dry-run, and give-up paths.

## Backlinks

- [[cli]]
- [[modules/babysitter]] · [[modules/config]] · [[modules/agent_profile]]
- [[operating]]
