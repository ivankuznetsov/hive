# Changelog

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
