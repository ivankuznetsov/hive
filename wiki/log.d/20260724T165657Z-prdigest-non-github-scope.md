---
title: PRDigest ignores registered non-GitHub workspaces
date: 2026-07-24
tags: [digest, prdigest, registry, bugfix]
---

# PRDigest ignores registered non-GitHub workspaces

`hive digest` now excludes well-formed registered projects that are
demonstrably outside PRDigest's GitHub scope: local remotes, other Git hosts,
and existing Git repositories with no `origin`.

The adapter still fails closed for malformed registry rows, malformed GitHub
identities, unavailable identity lookups, an empty GitHub scope, and
unregistered `--repo` filters. This restores digest operation in normal mixed
registries without allowing command input to expand the trusted repository
set.

Binary discovery also falls back to the installed `prdigest` gem executable
when RubyGems installed the runtime dependency outside the service's `PATH`.
`PRDIGEST_BIN` and an executable already on `PATH` keep their existing
precedence.

See [[commands/digest]], [[modules/digest]], and [[testing]].
