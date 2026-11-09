---
title: Harden benchmark shim review contracts and fixtures
type: fix
date: 2026-11-03
pages: [modules/workflows, testing]
tags: [bench, agent, shell, cleanup, review]
---

The stage caller now documents why controller-bin setup and cleanup errors
must remain on stdout for the driver's `stages.out` transcript. Its plan
continuation helper returns 1 for cleanup failure; the top-level caller still
exits 4.

The subprocess fixture canonicalizes its temporary root before adapting fixed
paths and retains the zero-residual guard. A full-caller regression uses a
symlinked temporary parent. The supplementary absence-probe check no longer
depends on variable spelling; regression samples verify braced variables,
hoisted paths, and bracket/test forms. The gh DEBUG observer is scoped to
the intended caller and checks optional variables before dereferencing them.
Direct `bash -u` subprocess tests cover inherited child shells and missing
controller-bin or expected-gh variables.

The two focused workflow files and installation integration file passed
76 tests and 4,142 assertions with no failures, errors, or skips (seed 41139).
Shell syntax, ShellCheck 0.11.0, and locked Ruby style checks passed. The
changed-test selector reported shared-runtime offline fallback; explicit
focused files were used with the existing ignored worktree-local bundle.
No full suite or exhaustive coverage run is claimed.
