---
title: Bound managed workflow outputs across Codex and Grok
date: 2026-07-26
---

**Changed:** Managed Honeycomb actors with bounded read and path-qualified
`Edit(...)` permissions can now map to Codex or Grok. Hive runs both providers
read-only, constrains their final response to the exact authorized file set,
validates it, and atomically materializes the files itself. Codex receives a
generated named filesystem profile with external tool surfaces disabled and
ignores user configuration/rules without persisting a session. Grok runs in an
isolated home inside bubblewrap with only declared read roots and its credential
file mounted. Output-set publication validates every value first, restores
earlier targets if a later atomic write fails, and writes the requested
stage/state artifact last as the completion commit point. Codex executable
discovery accepts a valid runtime provenance path even when unrelated aggregate
doctor checks fail, while retaining a dedicated bounded probe. That probe uses
an ephemeral empty Codex state root rather than scanning the operator's rollout
archive. Grok mappings also pin normalized reasoning effort via
`--reasoning-effort`. Typed launches retain normalized model,
requested/effective effort, model-pin, and effort-support receipts in the
private spawn log and `agent_start` event without logging prompt-bearing
provider argv.

**Safety:** Unbounded file rules, undeclared output paths, unsupported tools,
truncated/invalid/empty structured output, unavailable provider binaries, and a
missing Grok bubblewrap boundary all fail closed. Ordinary unmanaged stage
permission behavior and explicit managed `yolo` behavior are unchanged.

**Verified:** Focused runtime-policy, agent argv, profile identity, generic
stage, and council tests; RuboCop on all changed Ruby/test files; live Codex and
Grok read-boundary probes; and a dry-run plus activation of the Writing
workflow mapping with Sol high for writing/grounding and Grok 4.5 high for the
adversarial editor.
