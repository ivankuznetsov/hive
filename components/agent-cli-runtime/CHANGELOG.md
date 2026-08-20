# Changelog

## Unreleased

## 0.2.2 - 2026-08-18

- Treat Pi's `stopReason: "length"` as a typed `model_output_limit` failure.
  Pi exits zero after this provider stop even when the model exhausted its
  output allowance before writing the requested artifact; callers can now
  distinguish that incomplete turn from an agent that silently produced
  0 bytes and tell operators to raise `maxTokens` or lower reasoning effort.
- Declare Grok's filesystem sandbox flags, so a caller asking for confined
  execution gets it instead of being told Grok cannot confine. `--sandbox
  workspace` limits writes to the working directory and `--sandbox read-only`
  forbids them, both built-in profiles that custom ones extend from
  `~/.grok/sandbox.toml`; `--always-approve` suppresses the approval prompt a
  headless run can never answer, leaving the sandbox — not the prompt — as the
  boundary. Only the Grok profile changes.

## 0.2.1 - 2026-08-17

- Add per-profile provider-error extraction so a refusal a CLI reports on its
  event stream is distinguishable from an agent that genuinely produced
  nothing. `extract_provider_error` returns the provider, the HTTP status when
  the provider supplied one, and the redacted provider text.
- Add the `pi` extractor for turns that keep the envelope type and carry the
  refusal in `stopReason`/`errorMessage`, which no event-type match observes.
  Such turns previously reached the caller as a clean run with empty content
  while the process exited zero.
- Default every other profile to the previously assumed shapes — dedicated
  `error`, `turn.failed`, and `rate_limit_event` events plus failed `result`
  events — so no existing profile changes behaviour.
- Read usage from the assistant message and accept the bare
  `input`/`output`/`cacheRead`/`cacheWrite` spellings, so a provider reporting
  usage there is metered instead of silently recording nothing. The bare
  spellings are matched last, leaving a provider that reports explicit
  `*_tokens` keys with its existing reading.

## 0.2.0 - 2026-08-15

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
