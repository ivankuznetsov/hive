---
date: 2026-11-10
type: fix
---

OpenCode commands that Hive runs now pass `--standalone` when the binary
advertises it (OpenCode 2.x), so they get a private server instead of the
shared per-user background service on 127.0.0.1:49374. Without it, a command
with a different XDG identity failed because the port was taken, an attached
command was not guaranteed to load Hive's `OPENCODE_PERMISSION`,
`OPENCODE_CONFIG_CONTENT` or overlay, and a server started by a daemon-side
command outlived it.

- Hive native runs (`Hive::AgentSupport::OpenCode::Execution`) read
  `run --help` and pass the flag to `run` and the post-run `export`.
- Self-spawning launchers (daily digest, display name, diagnosis) get it from
  `Hive::Mcp.compile` through the OpenCode support module's `spawn_request`.
- The MCP adapter runs `debug config --help`, then `debug config --standalone`
  when advertised, for both launch isolation and `hive mcp import` discovery.
- agent-cli-runtime: the route probe records `:private_server` evidence and
  passes the flag to `auth list` and `models`; the prepared run and its
  sanitized export carry it; the profile declares `private_server`.
- OpenCode 1.x is unchanged. The remaining 2.x CLI drift is recorded in
  [[gaps]].
- Pages: [[modules/agent_cli_runtime]], [[modules/agent_profile]],
  [[modules/mcp]].
