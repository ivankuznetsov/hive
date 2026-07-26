# 2026-07-26 — Package Agent CLI Runtime inside the Hive monorepo

**Why:** HiveBench duplicates the same provider profile, preflight, argv, and
stream-decoding mechanisms, giving the boundary-ready Agent ABI a concrete
non-Hive adopter without justifying a separate repository.

**Change:** Added the self-contained `agent-cli-runtime` 0.1.0 component under
`components/agent-cli-runtime/`. It exposes `AgentCliRuntime`, the
`agent_cli_runtime` require path, immutable provider-neutral contracts for
Claude Code, Codex CLI, Pi, and Grok CLI, and the bounded `agent-runtime probe`
executable. Package and root parity tests prove clean loading, fail-closed
capabilities, non-default compile parity, local probes, custom capability
evidence, nested and absent usage variants, observable redaction, stable
local-probe output, and that Hive's current dependency graph is unchanged.
Probe hardening forwards the caller's environment, rejects ambiguous versions,
and bounds TERM/KILL cleanup for descendant-held pipes. Missing usage remains
unknown rather than a fabricated zero; Grok API-key auth ignores unused path
overrides; long and JSON-delimited secrets stay redacted.

**Release:** Added build-once candidate and private-install verification plus a
disjoint `components/agent-cli-runtime/vX.Y.Z` workflow. Only its
`agent-cli-runtime-release` environment receives RubyGems OIDC authority, after
Linux and macOS install the exact retained bytes. The pending publisher identity
and fix-forward procedure are documented in `docs/RELEASING.md`, together with
the required component-tag ruleset and release-environment reviewers. Release
jobs are bounded to 15 minutes and the candidate is retained for 30 days across
approval delays.

**Boundary:** Hive remains the canonical source repository, primary consumer,
and current authoritative implementation during the publication window. This
package-only change does not add a Hive runtime dependency, tag or release
Hive, publish the gem, merge the later Hive cutover, or make any other catalog
component package-eligible.
