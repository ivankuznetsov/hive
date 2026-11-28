---
title: hive version
type: command
source: bin/hive, lib/hive/cli.rb, lib/hive/runtime_identity.rb, schemas/hive-version.v1.json
created: 2026-09-02
updated: 2026-09-02
tags: [command, version, runtime, json]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-version) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive version` reports the release version; JSON mode additionally
identifies the active runtime channel, display version, build SHA, and
deployment.

## Implementation

Human output is `Hive::VERSION` followed by a newline, with exact top-level
`--version` and `-v` shortcuts handled in `bin/hive` before Thor dispatch. JSON
output captures `Hive::RuntimeIdentity`, allowing dogfood and installed
releases to share the same release semantic version while exposing their actual
loaded build and deployment identity.

## Tests

`test/unit/cli_test.rb` covers release text, dogfood runtime identity, and
validation against `hive-version.v1`; wrapper tests cover `--version` and `-v`.

## Backlinks

- [[cli]] · [[operating]] · [[release-candidate]]
