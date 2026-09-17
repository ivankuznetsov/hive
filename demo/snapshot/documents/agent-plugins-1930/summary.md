# Summary for migrate-every-agent-plugin-to-260709-3082

## Summary
All five shipped plugins can now be installed as self-contained packages on Claude Code, Codex, Pi, and OpenClaw while preserving their established Claude and Codex entrypoints. A validated surface contract and deterministic adapters make host parity, package isolation, and release metadata enforceable.

| Area | Reviewer-relevant outcome |
| --- | --- |
| Packaging | The shipped inventory is reconciled across both catalogs and plugin directories; generated Pi and OpenClaw surfaces remain self-contained when copied outside the checkout. |
| Workflow parity | Legacy Claude commands retain their names and argument grammars while loading canonical workflows; Agent Reviewer now applies the same multi-pass confidence gate on every host. |
| Screenote | MCP is replaced by an OAuth-first JSON CLI workflow with an argv allowlist, explicit auth/project failures, private capture recovery, cleanup, and credential-leak checks. |
| CI and releases | Contract, generation, semantic-parity, security, documentation, and isolated native-discovery checks cover all five plugins across the four pinned hosts. |

Screenote intentionally leaves annotation resolution as a UI step because `annotation resolve` is outside the approved CLI contract. Until an OAuth-first CLI release is tagged, compatibility remains pinned to the recorded public commit.

## PR
https://github.com/ivankuznetsov/agent-plugins/pull/21

## Commits
```
6ab2d95 docs(platforms): U7 publish migration and release guidance
d75af84 ci(platforms): U6 enforce native package discovery
29a9f95 test(screenote): U5 enforce CLI security contract
819d7ff feat(screenote): U4 replace MCP with JSON CLI
c90343b feat(workflows): U3 consolidate canonical plugin behavior
d6ae21f feat(packaging): U2 generate four-host packages
528d4b3 feat(packaging): U1 define plugin surface contract
```

## Review
Review passes: 1
Triage bias: courageous
