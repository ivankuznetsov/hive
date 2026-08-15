# Changelog

## Unreleased

- Add OpenCode `1.18.16+` as a fifth immutable built-in profile with exact
  `provider/model` routing and faithful model-variant validation.
- Add route-aware offline probing for the required run/export flags, selected
  authentication source, cached model inventory, and exact requested route.
- Add invocation-owned OpenCode config/data/cache/state overlays with
  deny-first `read-only` and `workspace-write` policies, explicit credential
  forwarding, owner-private resources, and idempotent cleanup.
- Add strict run/export correlation and typed outcomes for completion,
  authentication/configuration/CLI failure, malformed output, cancellation,
  and timeout while preserving requested versus actual route identity.
- Preserve unavailable separately from numeric zero for input, output,
  cache-read, cache-write, reasoning, and cost evidence.
- Keep process spawning, streaming, timeout/cancellation supervision,
  process-tree cleanup, retries, and post-run inspection execution with the
  caller; the component returns commands and normalizes captured evidence.

## 0.1.1 - 2026-08-11

- Expose each profile's immutable credential-environment key inventory so
  orchestrators can isolate named subscription/session bindings without
  embedding provider-specific compatibility tables.
- Expose each profile's configuration-directory override and home-relative
  default so orchestrators can detect subscription-session aliases without
  maintaining a second provider-specific table.
- Include Claude's ambient auth-token override in the isolation inventory so a
  named subscription binding cannot be silently replaced by caller state.
- Preserve an optional immutable provider signal in observable results so a
  trusted orchestrator can carry structured transport evidence without moving
  provider-health classification into the compatibility package.

## 0.1.0 - 2026-07-26

- Add immutable profiles for Claude Code, Codex CLI, Pi, and Grok CLI.
- Add provider-neutral invocation compilation, local prerequisite probes,
  capability evidence, usage extraction, and result normalization.
- Add the `agent-runtime probe` diagnostic executable with versioned JSON and
  stable exit statuses.
- Keep missing provider usage unknown instead of recording fabricated zero
  counts, and preserve typed unknown-provider errors through the public facade.
- Harden local probing around subprocess environments, ambiguous version
  output, TERM-resistant descendants, custom capability evidence, unused Grok
  credential paths, and long or JSON-delimited secrets.
