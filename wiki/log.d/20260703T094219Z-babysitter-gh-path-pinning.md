---
date: 2026-07-03T09:42:19Z
slug: babysitter-gh-path-pinning
pages: [modules/babysitter, testing]
---

## babysitter - pin PATH before gh dry-run passthrough

Fixed patrol finding `command-bin-hive-babysitter-stub-gh-1` by pinning
`PATH=/usr/bin:/bin` before `bin/hive-babysitter-stub-gh` execs an
allowlisted real `gh` read. The stub already scrubbed Git child-process env
seams; the new PATH pin prevents real `gh` repository probes from resolving a
caller-controlled `git` binary while credentials and passthrough environment are
still available.

Added focused `test/unit/babysitter/dry_run_env_test.rb` coverage where fake
real `gh` shells out to `git --version` while PATH points first at a poisoned
`git`. The test now proves the poisoned child `git` is not executed.

Updated [[modules/babysitter]] and [[testing]].
