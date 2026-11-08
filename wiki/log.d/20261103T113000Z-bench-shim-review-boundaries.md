---
title: Close benchmark shim continuation and publication gaps
type: fix
date: 2026-11-03
pages: [modules/workflows, testing, gaps]
tags: [bench, agent, shell, cleanup, review]
---

The packaged caller now cleans legacy agent shims before plan continuation
and again immediately before review after the publication agent runs. The
existing startup, pre-develop, and review-entry cleanup remains. The shared
helper owns the sealed-mode no-op and rejects a symlink anywhere in the
managed bin's canonical path before removing entries. Both cleanup diagnostic
reasons, including the initial mkdir failure, now reach driver-captured stdout;
failures still stop the caller with exit 4.

Full-caller regressions cover publication-agent replanting, plan continuation
success and failure, ancestor symlinks at startup and repeated boundaries,
stdout diagnostics, and a later Grok failure after Codex and Pi removal.
A Bash DEBUG observer checks gh bytes after repeated cleanup and before its
legitimate review-setup rewrite. Executing the unchanged cleanup helper four
times in sealed mode preserves managed entries even with a symlinked bin.
The supplementary source check examines only post-removal absence probes;
executable denial tests prove removal-status handling without fixing one
equivalent conditional spelling in place.

Five new regressions failed against the preceding script before implementation.
After the fix, the two focused workflow files plus the installation integration
file passed under the locked bundle: 73 tests, 4,004 assertions, no failures,
errors, or skips. Shell syntax, ShellCheck 0.11.0 using the install-smoke shell
lint invocation, and locked Ruby style checks passed on the final script/test.
The earlier missing-ShellCheck limitation for `694e1bc80c` remains historical.
The initial plain-Ruby combined run could not load dependencies in eight
neighboring tests; an isolated ignored worktree-local bundle resolved those
failures. The changed selector reports broad offline fallback for the shared
runtime, so explicit focused files were used. No full suite or coverage run
is claimed.

[[gaps]] now also records residual PATH shadowing by unrelated `hive`, `git`,
and `ruby` entries without expanding the three-name cleanup allowlist. Exact
tested-revision and completed-file timing evidence is maintained in [[testing]].
