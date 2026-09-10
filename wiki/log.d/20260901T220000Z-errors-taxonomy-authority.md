---
title: Make lib/hive/errors.rb authoritative for the error taxonomy
date: 2026-09-01
tags: [architecture, errors, cli, component-boundaries]
---

- Moved the concrete error taxonomy (InvalidTaskPath, UsageError,
  ConcurrentRunError, GitError/RebaseConflict, AgentError,
  ProviderRouteFailed, WrongStage/ConditionGateBlocked, install
  drift/failed pairs, DependencyWait/Admission, AttemptExecutionError,
  and the rest) verbatim out of `lib/hive.rb` into
  `lib/hive/errors.rb`. The dedicated clean-loadable errors boundary is
  now the single authority for both the exit-code contract and the
  concrete classes; the root entrypoint keeps only
  `require_relative "hive/errors"`.
- No behavior change: public constant paths, `exit_code` overrides, and
  inheritance (IS-A for exit-code convenience, e.g.
  `ProviderRouteFailed < AgentError`, `ConditionGateBlocked <
  WrongStage`, `AmbiguousSlug < InvalidTaskPath`) are unchanged.
- Added `test/unit/errors_authority_test.rb` pinning the ownership
  contract, mirroring the `Schemas` precedent (`lib/hive/schemas.rb`
  owning the schema namespace): the taxonomy must be defined in
  `errors.rb`, `lib/hive.rb` must declare no error subclasses, and the
  file must load exactly once per `require "hive"`.
- Fixed a stale wiki reference in [[modules/rebase]] that still located
  `Hive::RebaseConflict` in `lib/hive.rb`.