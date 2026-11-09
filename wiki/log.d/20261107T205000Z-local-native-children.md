---
title: Pin internal native children to their local installation
date: 2026-11-07
---

Task naming, daemon, bot, one-shot and TUI launches now add an explicit local
context to native Hive children that have no explicit context option. A saved
remote client selection therefore cannot retarget local work after admission.
Logical command metadata stays unchanged; non-Hive executables and literal
arguments keep their existing grammar. Real-child regressions reproduce the
previous remote-context rejection and verify local execution while the saved
selection still points elsewhere.

Managed daemon, web, bot and babysitter startup now selects the local installation
in rendered and shipped systemd/launchd definitions. Daemon code-refresh and
babysitter detached-restart re-exec also retain local custody. The context option
follows the existing startup arguments, preserving service command signatures,
resolved binaries and environment. Rendered-argv and preflight regressions cover
all four services while a remote client selection remains saved.
