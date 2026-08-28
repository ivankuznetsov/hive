# Fix: operator-owned `hv` aborts an otherwise successful install

- **Date:** 2026-08-28
- **Actor:** Codex
- **Area:** `install.sh` user-bin launcher publication; [[operating]]
- **Type:** bugfix

## What happened

The unconflicted launcher path invokes `publish_managed_link` for `hv` after
publishing `hive`. Preserving an operator-owned `hv` is an expected outcome,
but the helper reports that ownership collision with status 1. Because the call
was a bare command under `set -e`, a host without another `hive` earlier on
`PATH` aborted the installation immediately after correctly preserving `hv`.

The regression test passed on development hosts that happened to provide
`/usr/bin/hive`, which selected the separate collision-fallback branch. A clean
GitHub runner selected the intended unconflicted branch and exposed the abort.

## Fix

Treat the `hv` publication result as advisory in the unconflicted branch. The
helper still warns and preserves the operator-owned destination, while the
installer continues with preflight, migration, and daemon setup.

The regression test now places the managed `hive` launcher first on its fake
`PATH`, so it deterministically exercises this branch regardless of software
installed on the host.
