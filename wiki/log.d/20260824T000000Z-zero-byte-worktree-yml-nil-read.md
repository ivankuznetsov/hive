# 2026-08-24 — Zero-byte `worktree.yml` raised NoMethodError instead of WorktreeError

## What changed

`Hive::Worktree.read_strict_pointer` and `read_owned_pointer` crashed with
`NoMethodError: undefined method 'bytesize' for nil` when `<task_folder>/worktree.yml`
was zero bytes. `IO#read(length)` returns `nil` (not `""`) at EOF, so the
`value.bytesize` size check blew up before YAML parsing could reject the empty
content. Both readers now normalize the read result with `|| ""`, so an empty
pointer fails as `WorktreeError` ("worktree.yml must be a hash") like any other
invalid content.

- `lib/hive/worktree.rb`: coerce `file.read(...)` nil → `""` in both strict/owned readers.
- `test/unit/worktree_test.rb`: regression tests for zero-byte files against both readers.

## Impact

Callers rescuing `WorktreeError` around pointer reads (stages, task closure,
web, auto-retry safety) now handle truncated/empty pointer files instead of
crashing on an unhandled `NoMethodError`. Public contracts unchanged.
