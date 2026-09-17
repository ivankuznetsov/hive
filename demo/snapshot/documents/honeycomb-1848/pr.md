---
pr_url: https://github.com/ivankuznetsov/honeycomb/pull/1
pr_number: 1
---

# feat(registry): honeycomb-manifest/v1 contract and offline tooling

## Summary

Honeycombs now have a publishable, verifiable v1 contract: immutable SemVer version directories, canonical generated manifests, fail-closed permission summaries, read-only validation, and an approval-gated deterministic catalog. The three offline Ruby-stdlib commands share one implementation, preventing schema, integrity, permission, evidence, and serialization rules from drifting between authors and CI.

The package boundary rejects ambiguous YAML, traversal, symlinks, special files, unsupported permission constructs, and stale review identities before approving or replacing generated output. Root `packages/` and `catalog.json` intentionally remain empty until the seed-package task lands; listing CI, trust policy, site rendering, and Hive installation remain owned by their linked sibling tasks.

Session-settled decisions carried from planning: generated manifests with read-only validation; immutable version directories; fail-closed worst-case permissions; dual-evidence catalog gating; standalone structural checks plus explicit Hive compatibility; and a strict independent v1 schema (all user-directed).

## Test plan

- [x] `ruby test/run.rb` — 65 runs, 327 assertions, 0 failures, 0 errors, 0 skips.
- [x] `ruby script/honeycomb-manifest --check --all` — exit 0.
- [x] `ruby script/honeycomb-validate --all --json` — empty finding array, exit 0.
- [x] `ruby script/honeycomb-validate --all --json --require-hive` — strict compatibility check passed with the pinned Hive runtime.
- [x] `ruby script/honeycomb-catalog --check --evidence test/fixtures/listing-evidence/empty.json` — exit 0.
- [x] `git diff --check` — clean.

The suite covers deterministic bytes across locale/timezone changes, SemVer precedence, evidence omission and identity mismatch, tampered payloads, unsafe YAML, traversal, symlinks, special files, and the end-to-end manifest → validation → catalog flow from another working directory.

## Review summary

Review pass 01 produced no findings. Triage had no escalations or user questions, and the fix phase completed successfully.

## Linked task

Hive task `1848` — Package Registry Manifest Schema (`registry-layout-package-manifest-schema-260709-1f1a`).

---

[![Compound Engineering](https://img.shields.io/badge/Built_with-Compound_Engineering-6366f1)](https://github.com/EveryInc/compound-engineering-plugin)
![Claude Code](https://img.shields.io/badge/Opus_4.8-D97757?logo=claude&logoColor=white)

<!-- COMPLETE pr_url=https://github.com/ivankuznetsov/honeycomb/pull/1 is_draft=false -->
