# 2026-10-15 — Hive owns the MCP servers of every agent it launches

- New global catalog `mcp.servers` and per-project/stage grants `mcp.use`
  (`Hive::Mcp::Settings`). Launches render only granted servers: Claude
  `--strict-mcp-config` + a per-launch 0600 file, Codex `--ignore-user-config`
  + `-c mcp_servers.*` with carried-over personal settings, OpenCode
  disable-by-enumeration, Pi `--no-mcp` (floor 1.0.4 via
  `agents.pi.min_version`). Grok is reported by doctor as unisolated.
- New `hive mcp import` / `hive mcp login` ([[commands/mcp]],
  `hive-mcp-import.v1`); `hive setup` and `hive init` offer the import once.
- `hive doctor` gains `mcp/*` rows. ADR-054 amends ADR-051. The uncalled
  Claude `mcp_config_path:`/`strict_mcp_config:` keywords and the dead Codex
  `-c mcp_servers={}` isolation entry are gone. See [[modules/mcp]] and
  [[gaps]].
