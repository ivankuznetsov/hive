---
title: Make CLI command owners authoritative
date: 2026-09-02
tags: [cli, wiki, commands, documentation, regression-guard]
---

- Made rendered `bin/hive help`, the two-column command index in `wiki/cli.md`,
  and the linked command/module owner pages one checked contract. The current
  run derived 58 visible commands from real help; that count is evidence, not a
  pinned list. Every rendered command has one row, one allowed owner link, and
  a complete owner contract.
- Kept `pr`, `--version`, and `-v` as aliases of `open-pr`/`version` without
  duplicate index rows. Hidden commands are derived from Thor metadata and
  must remain absent from help and the index without pinning their names or
  count; inherited `help` and `tree` remain visible and have dedicated owners.
- Maintainers changing a public command now update its owner, update the index
  only when surface or ownership changes, extend focused coverage, and append
  one log fragment. Supporting stage links may live inside an owner page but
  are rejected as index owners.
- Focused verification passed: command-index unit 18 runs / 92 assertions;
  real-help integration 1 / 30; metrics integration 20 / 90; act unit 9 / 48;
  daemon integration 89 / 406 with one intentional skip; CLI unit 56 / 306;
  Wiki integration 7 / 21. Nested daemon subprocesses required the already
  active `Gem.path` exported because their disposable `HOME` otherwise hid
  this host's user-installed bundle.
- `bundle exec rake test` reached 130 runs / 1,275 assertions with one skip and
  one pre-existing `agent-cli-runtime` failure: the host resolves `codex` to
  `/home/asterio/.local/share/mise/installs/codex/0.147.0/bin/codex`, while the
  test expects the bare token. The same failure reproduced from unchanged
  `origin/main` `c11abdba6dad4dab1a0d4e3adbc37a87b32cb322`
  (16 runs / 111 assertions); verified head
  `618e005ca77ffcfe987e0d434ebf87139adb2bb8` changes no component or runtime
  source. `git diff --check` passed, with no changes under `bin/`, `lib/`, or
  `schemas/`.
