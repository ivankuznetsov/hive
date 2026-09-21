---
title: Secret detection and diagnostic redaction
type: module
source: lib/hive/secret_scanner.rb, lib/hive/secret_patterns.rb, lib/hive/betterleaks.rb
created: 2026-04-26
updated: 2026-09-06
tags: [security, secrets, betterleaks, redact]
---

**TLDR**: Betterleaks is the sole credential detector. Hive selects exact inputs
and maps findings into workflow decisions; it does not maintain detection regexes
or its former Ruby password-reference classifier. `SecretPatterns` now exposes
only in-process diagnostic redaction, never a publication approval API.

## Detection

`SecretScanner.scan(text, path:)` returns redacted finding metadata: upstream
rule name, line/column, path, and a SHA-256 of the complete secret for exact
existing-finding comparisons. Raw scanner reports exist only in memory.
`match?` is the boolean wrapper. A failed command or malformed report raises
`SecretScanner::Unavailable`; callers must not interpret it as no findings.

Git publication scans the exact base..HEAD history using Betterleaks Git mode,
including intermediate commits and binary bytes forced through text diffs.
Auto-commit scans exact index blobs, subtracting identical existing HEAD
findings, without rejecting a blob because of its size. Review scans batch
added lines by filename so upstream code-aware filters see source context.

The same detector serves PR bodies/comments, artifact checks, workflow-package
secret checks (both authoring lint and import lint), benchmark submission, and
retry safety. Workflow-package behavior/permission lint is
separate from credential detection and remains intact.

Hive uses the bundled upstream rules, disables network credential validation,
and disables global path skips and inline suppression comments. An empty
private Git view prevents task-authored config or ignore files from disabling
the scanner. Hardened Git config and exact-OID validation remain in force.

## Redaction

`SecretPatterns.redact(text)` masks diagnostic strings without spawning a process
inside status/log formatting. It preserves UTF-8, handles binary log tails,
redacts complete and truncated PEM blocks, and does not mutate its input.
The former `scan`, `match?`, `match_diff?`, and password-reference APIs are gone.
Existing diagnostic receipts retain their numeric redaction-version metadata;
reading them still checks their contents with the current Betterleaks detector.

## Distribution and tests

See [[dependencies]] for pinned bundled binaries and build-time verification.
`test/unit/secret_scanner_test.rb` exercises the real Betterleaks binary,
large inputs, binary payloads, source context, suppression resistance, and
failure handling. Publication/auto-commit/handoff tests cover their boundaries;
`secret_patterns_test.rb` now tests diagnostic redaction only.

## Backlinks

- [[stages/open-pr]] · [[stages/review]] · [[dependencies]]
