---
title: Scope Wiki owner contracts to commands
date: 2026-09-02
tags: [cli, wiki, commands, regression-guard, review]
---

- Reduced the static owner map to the durable aggregate-owner pins and made
  the navigation index authoritative for every other command. Missing pins,
  new unpinned commands, and command-specific contracts are now checked
  independently.
- Made owner validation fence-aware and command-scoped, with explicit
  requirements for meaningful option, behavior, schema, serialization, error,
  and exit-code text. The six shared owners now provide compact per-command
  contract rows instead of lending page-level prose to unrelated commands.
  Single-owner pages likewise reject sections that explicitly describe a
  different command, and hidden Markdown cannot satisfy structural checks.
- Kept `wiki/cli.md` navigation-only by rejecting command contract tables,
  prose, and lists outside its bounded index. Broadened the no-write proof to
  include directories, transient create/delete activity, and Git control data.
- Corrected workflow and module pre-dispatch schema routing, the Thor `tree`
  exclusions, and restored an unrelated OpenCode test helper ordering change.

Focused verification covers the pure guard, real `bin/hive help`, wrapper
version aliases, repository snapshots, and the OpenCode lifecycle regression.
