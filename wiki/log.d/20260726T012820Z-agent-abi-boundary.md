## 2026-07-26 — Agent ABI promoted below Hive orchestration

- Added `Hive::AgentRuntime` as the supported provider-neutral entry point
  with immutable request, compiled invocation, capability/probe evidence, and
  observable-result values.
- Preserved the optional-keyword `Hive::AgentProfile` constructor and
  `Hive::AgentProfiles.register` extension point; Claude, Codex, Pi, Grok, and
  custom profiles remain provider adapters.
- Routed headless Agent, diagnosis, display-name, patrol capability, stage,
  reviewer, TUI, and interactive-launcher preparation through the runtime
  boundary while keeping process lifetime, timeouts, retries, workflow policy,
  artifact acceptance, and stage success in Hive.
- Unsupported requested capabilities now fail closed with typed evidence;
  probe diagnostics are bounded and secret-redacted.
- Promoted `agent-abi` to `boundary-ready` in the component catalog. Shared
  `Hive::SecretPatterns` is no longer claimed as artifact-firewall-owned state.
