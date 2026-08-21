# Changelog

## Unreleased

## 0.2.0 - 2026-08-15

- Add first-class OpenCode `1.18.16+` support alongside the built-in Claude
  Code, Codex CLI, Pi, and Grok CLI profiles. OpenCode uses the shared request
  and facade, then adds provider-specific preparation, route probing, and
  strict result normalization.
- Route every OpenCode run to an exact `provider/model` and validate model
  variants, preserving the route the application requested and the route the
  captured result reports.
- Prepare owner-private OpenCode config, data, cache, and state overlays for
  each invocation, with scoped `read-only` and `workspace-write` policies,
  deliberate credential forwarding, and idempotent cleanup.
- Check run/export capabilities, selected authentication source, cached model
  inventory, and the exact requested route locally before an application
  starts work.
- Correlate run and sanitized-export evidence into typed outcomes for
  completion, authentication, configuration, CLI failure, malformed output,
  cancellation, and timeout.
- Report input, output, cache-read, cache-write, reasoning, and cost evidence
  while preserving the difference between unavailable data and numeric zero.
- Return prepared commands and normalized evidence through lifecycle-safe
  values that fit an application's existing streaming, timeout, cancellation,
  retry, and process-supervision stack.

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
