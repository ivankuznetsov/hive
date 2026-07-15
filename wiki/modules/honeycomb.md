---
title: Hive::Honeycomb
type: module
source: lib/hive/honeycomb.rb, lib/hive/honeycomb/**/*.rb
created: 2026-07-15
updated: 2026-07-15
tags: [module, workflow, honeycomb, registry, integrity, transaction]
---

**TLDR**: `Hive::Honeycomb` manages immutable workflow packages from the one
public `github.com/ivankuznetsov/honeycomb` Git registry. It turns a catalog
reference into a verified regular-file inventory and derived security report,
stores sufficient lock metadata for offline ownership inspection, and applies
install/update/remove changes through one recoverable `hive/state` transaction.

## Immutable input boundary

- `Reference` parses only `honeycomb/<safe-name>[@selector]`. Selectors are exact
  SemVer, Git SHA/prefix, or recorded package digest; mutable aliases and partial
  SemVer are invalid.
- `Catalog` accepts a closed version-1 YAML shape. Each workflow has an exact
  `latest` version and unique release records containing version, safe tag, full
  object ID, and SHA-256 package digest. It returns a `ResolvedPin` with selector
  intent as well as immutable coordinates.
- `Registry` owns a bare Git repository and validated catalog snapshot below
  `Hive::Paths.honeycomb_cache_dir`. Only explicit network operations refresh
  it. Fetch tries the public repository's `main`/`master`, verifies commit
  peeling and tag agreement, and atomically publishes a new snapshot only after
  catalog validation. Raw tree/blob access stays behind this collaborator so
  tests use local bare registries.

No project configuration, environment variable, authentication flow, mirror,
or alternate source changes the V1 registry identity.

## Package and security verification

`Package#verify` enumerates `workflows/<name>/` through NUL-delimited Git tree
metadata and rejects everything except normal `100644`/`100755` blobs. It
normalizes each package-relative path before any write, requires the tree to be
exactly `manifest.yml` plus the manifest inventory, hashes every raw blob, and
recomputes the canonical package digest.

The package-native `workflow.yml` is parsed with its enclosing package name as
the expected descriptor ID. Every descriptor instruction must remain inside the
root, be manifest-listed, and contain valid UTF-8. The verified files (but not
`manifest.yml`) are materialized in a hidden same-filesystem staging directory.

`SecurityReport` derives permission presets, tools, directories, Bash/shell
exposure, shell-shaped fenced blocks/lines, and stable high-risk categories from
the parsed descriptor/inventoried instructions. A publisher manifest may be
conservatively broader, but may not understate the derived exposure. Reports are
deterministic approval data, not an execution engine or safety proof.

## Durable local state

`Lockfile` stores deterministic version-1 YAML at
`<hive_state_path>/workflows/.honeycomb.lock`. Entries contain source/name,
resolved SHA/version/tag/digest, requested selector kind/value, sorted file
hashes/modes, and the full security summary/findings. Invalid lock content is a
typed error rather than an empty install set.

`Installation` compares the complete regular-file tree with a lock entry and
classifies it as `clean`, `dirty`, `missing`, or `extra_file`, including
type-changed paths. This powers network-free list, collision protection, and
removal ownership checks.

`Diff` compares old lock/inventoried content with a verified candidate. It emits
semantic permission changes plus an escalation flag, full unified diffs for
added/removed/changed instruction files, descriptor change state, asset change
sets, and metadata-only status.

## Transaction and recovery

`Transaction` operates under `Hive::Lock.with_commit_lock`. A versioned journal
records the old `hive/state` head, exact target/backup pairs, affected names, and
phase before renames. Existing package roots, authored collision files, and the
lock are backed up on the same filesystem; candidates/removals and the new lock
are swapped; only exact workflow pathspecs are staged; one commit records the
entire operation.

Any pre-commit failure restores target bytes and reconciles only the
transaction-owned index paths. A later mutation rolls back an interrupted
pre-commit journal, while a committed/head-advanced journal is cleaned without
restoring old files. Multi-package updates share one journal and lock revision.
Missing/malformed-lock removals intentionally omit lock replacement, touch only
the canonical managed root, and return a non-zero partial result even after
successful best-effort cleanup.

## Backlinks

- [[commands/workflow]]
- [[modules/git_ops]]
- [[modules/lock]]
- [[modules/workflows]]
- [[testing]]
