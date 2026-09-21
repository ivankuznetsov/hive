---
title: hive publication-reconcile
type: command
source: lib/hive/cli.rb, lib/hive/commands/publication_reconcile.rb, lib/hive/github_publication.rb
created: 2026-09-09
updated: 2026-09-09
tags: [command, publication, recovery]
---

**TLDR**: Adopt an explicitly inspected hosted PR revision into a task's local
publication record after an external rewrite.

## Usage

```sh
hive publication-reconcile TARGET --pr PR_URL --head FULL_INSPECTED_HEAD [--project NAME] [--json]
```

## Options

`--pr` and `--head` are required. Supply `--head` as the exact lowercase
40-hex commit OID; other spellings fail the stale-authority comparison.
`--project` scopes task resolution to one registered project. `--json` selects the unversioned observation object.

## Behavior

The command resolves the task, loads its configuration, and locks the task.
An existing coding publication record and clean owned worktree are required.
The controller checks the inspected head against local and remote identities,
runs secret scanning, authenticates, verifies the task's PR identity, and
revalidates the request before updating the local publication record.
It does not push, edit GitHub, clear a marker, or approve code. Subsequent
workflow retry still owns advancement. See [[publication-recovery]] for context.

## Output and schema

Text output names the task, reconciled PR URL, and head OID. JSON output is
schema-less and unversioned: the recorded PR fields are augmented with
`head_oid`, `hosted_state`, `observed_at`, and `diff_digest`. There is no
command-specific error envelope.

## Errors and serialization fallback

Missing records, stale heads, mismatched PR identity, unsafe state, and failed
secret checks refuse reconciliation. Typed errors retain the shared CLI stderr
and exit behavior. JSON encoding errors propagate; no fallback JSON document is
emitted. Shared runtime activation errors retain their separate wrapper contract.

## Exit codes

Exit code `0` means reconciliation succeeded. Publication refusals inherit
exit code `1`; usage errors use `64`, task-lock contention uses `75`, and
configuration errors use `78`. Other typed failures retain their shared CLI
exit code rather than being remapped by this command.

## Examples

```sh
hive publication-reconcile TASK --project PROJECT --pr PR_URL --head FULL_INSPECTED_HEAD --json
```

## Backlinks

- [[cli]] · [[publication-recovery]]
