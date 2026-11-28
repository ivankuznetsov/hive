---
title: hive publication-reconcile
type: command
source: lib/hive/cli.rb, lib/hive/commands/publication_reconcile.rb, lib/hive/github_publication.rb
created: 2026-09-09
updated: 2026-11-19
tags: [command, publication, recovery]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-publication-reconcile) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: Adopt an explicitly inspected hosted PR revision into a task's local
publication record after an external rewrite.

## Behavior

The command resolves the task, loads its configuration, and locks the task.
`--head` must be the exact lowercase 40-hex commit OID for the stale-authority
comparison. An existing coding publication record and clean owned worktree are required.
The controller checks the inspected head against local and remote identities,
runs secret scanning, authenticates, verifies the task's PR identity, and
revalidates the request before updating the local publication record.
A qualifying GitHub retarget of a stacked PR is adopted here exactly as in
ordinary publication; any other base change is refused. It does not push, edit
GitHub, clear a marker, or approve code. Subsequent workflow retry still owns
advancement. See [[publication-recovery]] for context.

## Backlinks

- [[cli]] · [[publication-recovery]]
