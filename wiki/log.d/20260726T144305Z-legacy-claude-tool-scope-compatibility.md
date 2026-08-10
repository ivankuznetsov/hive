## 2026-07-26 — Legacy custom Claude tool scopes remain compatible

- Preserved `--allowedTools` / `--disallowedTools` for existing custom
  `AgentProfile` registrations named `claude` that omit the new
  `tool_scope_flags:` keyword.
- Kept an explicit empty `tool_scope_flags: {}` as the opt-out for adapters
  that intentionally do not expose Claude's native tool-scope flags.
- Added focused runtime coverage for both paths and for the successful
  immutable `ProbeResult` value contract.
