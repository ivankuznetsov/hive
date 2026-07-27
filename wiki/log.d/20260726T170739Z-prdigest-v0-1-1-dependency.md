---
title: Hive consumes PRDigest v0.1.1
type: log
tags: [digest, prdigest, dependency, bugfix]
---

# Hive consumes PRDigest v0.1.1

Hive's runtime dependency, installed-gem executable fallback, root lockfile,
managed-web lockfile, focused tests, and operator wiki now target
`prdigest ~> 0.1.1`.

PRDigest v0.1.1 normalizes native `Time` values returned by Octokit for merged
pull-request timestamps. That prevents live GitHub results from failing
PRDigest's response validation while preserving Hive's deterministic
`prdigest run` invocation and `prdigest-result` v1 pass-through.

The published gem was downloaded from RubyGems and matched the release
artifact byte-for-byte; a clean remote install reported `prdigest 0.1.1`.

Remaining uncertainty is limited to a retained live Telegram delivery proof.
Dry-run coverage exercises the fetch, render, chunk, and result path without
mutating digest state or sending messages.
