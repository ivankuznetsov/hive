# 2026-11-05 — Muse review fixes

**Action:** Addressed the PR #1603 code review.
- `Hive::DiagnosisAgent` now spawns with a 0600 regular-file stdin
  (`popen_with_stdin_file`) instead of a popen3 pipe, so Muse's
  `--prompt-file=/dev/stdin` works for `hive status --diagnose`.
- The Muse profile drops `configuration_environment_key` (it named the
  shared `XDG_CONFIG_HOME` base). `LaunchBindings.resolve` lets a profile
  without a configuration key run on the `default` binding and refuses named
  bindings for it.
- Provider routing no longer advertises the `mcp` tool for Muse, which has no
  Hive MCP renderer.
- `Muse::PluginStaging` refuses symlinks resolving outside the cloned
  repository and drops dangling links.
- `Muse::Skills` shares `registry_path`/`manifest_repository` with the setup
  adapter, and live inventory resolves relative `cache_path` like the
  filesystem inventory. `SENSITIVE_LINE` is derived from
  `SENSITIVE_PAYLOAD_TYPES`.

**Verification:** diagnosis, launch-binding, Muse agent/skill/CE/staging,
inspector, provider-routing, and agent-cli-runtime Muse/runtime tests pass
locally.

**Wiki:** Updated [[gaps]], [[modules/agent_support]], and [[token-usage]].
