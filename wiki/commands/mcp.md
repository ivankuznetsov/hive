---
title: hive mcp
type: command
source: lib/hive/commands/mcp.rb
created: 2026-10-15
updated: 2026-10-15
tags: [command, mcp, config, json]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-mcp) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive mcp import` copies the MCP servers you choose from your personal agent configs (Codex, Claude, OpenCode, Pi, Grok) into Hive's global catalog, `mcp.servers` in `~/.config/hive/config.yml`. Hive-launched agents load only catalog servers that a project or stage grants with `mcp.use` (see [[modules/mcp]]). `hive mcp login SERVER --agent AGENT` signs one agent in to an OAuth catalog server so headless launches can reuse the login. Owner module: `Hive::Commands::Mcp`; discovery and writes live in `Hive::Mcp::Discovery` and `Hive::Mcp::Importer`.

## Behavior

1. Discovery is read-only. Codex servers come from `codex mcp list --json` (user and trusted-project servers plus each one's login state), OpenCode from `opencode debug config`, Claude from `~/.claude.json` (`mcpServers` and `projects[<cwd>].mcpServers`) and `<cwd>/.mcp.json`, Pi from `~/.pi/agent/mcp.json` and `.pi/mcp.json`, Grok from `$GROK_HOME/config.toml`. An agent that cannot be read is skipped with a notice.
2. Each entry is converted to the catalog shape. A `${VAR}`, `{env:VAR}` or `$VAR` reference becomes `bearer_token_env`, `headers_env` or `env_from`. A literal bearer token or secret-looking header or env value is replaced by a suggested variable name that the command lists for export; the literal is never written. Values built from a shell command (`!cmd`) or a partial interpolation are refused.
3. Rows are compared with the catalog: `new`, `imported`, `drift` (URL, argv or env names changed at the source), `catalog-only` (imported earlier, now gone), `conflict` (agents disagree on one name), `refused`. Drift is never applied without `--update`.
4. OAuth servers record `oauth_logins`: the agents that hold a saved login, read by key only (Codex `auth_status`, Claude `mcpOAuth` keys, Pi `mcp-auth.json` keys). Rendering skips an OAuth server for an agent without a login and logs a `hive mcp login` hint.
5. Writes go through `Hive::Config.update_global_config!` under the global config lock and keep every other key. The new block is validated before it is written.
6. `login` runs the agent's own flow in the terminal. Codex runs `codex mcp login SERVER` with `-c mcp_servers.SERVER.url=…` (and `oauth_resource`, `--scopes`) so the saved key matches Hive's rendering. Claude runs `claude mcp login SERVER`, which finds the server in Claude's own config. On success the agent is added to the server's `oauth_logins`.
7. `hive setup` and `hive init` ask once, in a terminal, to import the `new` rows and record `mcp.import_offered: true` whatever the answer. `--yes`, `--json` and non-TTY runs skip the question.

## Backlinks

- [[cli]] · [[modules/mcp]] · [[modules/config]] · [[commands/doctor]] · [[commands/setup]] · [[commands/init]]
