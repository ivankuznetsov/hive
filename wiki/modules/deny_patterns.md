---
title: Hive::DenyPatterns
type: module
source: lib/hive/deny_patterns.rb, lib/hive/honeycomb/preflight.rb
created: 2026-07-10
updated: 2026-07-10
tags: [security, honeycomb, publishing, shell]
---

**TLDR**: Immutable, versioned high-risk shell rules used by honeycomb preflight. Findings expose rule/file/line/remediation without matched text; the shared download-to-interpreter regex is also consumed by the review fix guardrail.

`RULE_SET_VERSION = 1`. Stable rule ids are:

- `shell_download_to_interpreter` — `curl`/`wget` piped to an interpreter.
- `credential_path_access` — shell reads from SSH, AWS, gh, or gcloud credential paths.
- `outbound_data_transfer` — curl upload of a local file or standard input.

Every rule descriptor records severity, target capability (`Bash`), description,
remediation, and regex. `scan(text, file:)` is binary-safe and returns frozen
findings without a snippet. Honeycomb preflight blocks a finding in README,
assets, descriptors, inherited/yolo contexts, or shared instructions with any
unjustified owner. Only an instruction whose every owner explicitly declares
scoped Bash and a non-empty `shell_justification` becomes a manifest
`review_required` record.

## Backlinks

- [[commands/workflow]]
- [[modules/secret_patterns]]
- [[stages/review]]
