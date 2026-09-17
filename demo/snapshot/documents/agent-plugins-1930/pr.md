---
pr_url: https://github.com/ivankuznetsov/agent-plugins/pull/21
pr_number: 21
---

## Summary

All five shipped plugins can now be installed as self-contained packages on Claude Code, Codex, Pi, and OpenClaw while preserving their established Claude and Codex entrypoints. A validated surface contract and deterministic adapters make host parity, package isolation, and release metadata enforceable.

| Area | Reviewer-relevant outcome |
| --- | --- |
| Packaging | The shipped inventory is reconciled across both catalogs and plugin directories; generated Pi and OpenClaw surfaces remain self-contained when copied outside the checkout. |
| Workflow parity | Legacy Claude commands retain their names and argument grammars while loading canonical workflows; Agent Reviewer now applies the same multi-pass confidence gate on every host. |
| Screenote | MCP is replaced by an OAuth-first JSON CLI workflow with an argv allowlist, explicit auth/project failures, private capture recovery, cleanup, and credential-leak checks. |
| CI and releases | Contract, generation, semantic-parity, security, documentation, and isolated native-discovery checks cover all five plugins across the four pinned hosts. |

Screenote intentionally leaves annotation resolution as a UI step because `annotation resolve` is outside the approved CLI contract. Until an OAuth-first CLI release is tagged, compatibility remains pinned to the recorded public commit.

## Test plan

- `python3 scripts/validate-agent-packages.py --inventory`
- `python3 scripts/generate-agent-packages.py --check`
- `python3 -m unittest discover -s tests` — 37 offline tests passed
- Screenote skill lint and security validation passed, including mocked error, cleanup, recovery, and sentinel-redaction paths.
- Native discovery found all five copied packages and their expected skills on Claude Code, Codex, Pi, and OpenClaw.

The credentialed Screenote integration remains isolated in a protected, manually dispatched workflow; deterministic mocks exercised its contract without live credentials.

## Review summary

Automated review pass 01 produced no findings. Triage found no escalations or unresolved user questions.

## Linked task

Hive task: `migrate-every-agent-plugin-to-260709-3082` — approved plan “Migrate Every Agent Plugin to Claude Code, Codex, Pi, and OpenClaw.”

<!-- COMPLETE pr_url=https://github.com/ivankuznetsov/agent-plugins/pull/21 is_draft=false -->
