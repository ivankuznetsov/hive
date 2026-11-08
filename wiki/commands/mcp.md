---
title: hive mcp
type: command
source: lib/hive/commands/mcp.rb
created: 2026-10-15
updated: 2026-10-15
tags: [command, mcp, config, json]
---

**TLDR**: `hive mcp import` copies the MCP servers you choose from your personal agent configs (Codex, Claude, OpenCode, Pi, Grok) into Hive's global catalog, `mcp.servers` in `~/.config/hive/config.yml`. Hive-launched agents load only catalog servers that a project or stage grants with `mcp.use` (see [[modules/mcp]]). `hive mcp login SERVER --agent AGENT` signs one agent in to an OAuth catalog server so headless launches can reuse the login. Owner module: `Hive::Commands::Mcp`; discovery and writes live in `Hive::Mcp::Discovery` and `Hive::Mcp::Importer`.

## Usage

```
hive mcp import                         # terminal: table, then choose rows
hive mcp import --dry-run [--json]      # plan only; writes nothing
hive mcp import --all --yes             # every `new` row
hive mcp import --only linear,docs --yes
hive mcp import --all --update --yes    # also replace `drift` rows
hive mcp login linear --agent codex     # interactive sign-in for Hive launches
```

## Options

| Option | Applies to | Meaning |
|---|---|---|
| `--all` | import | Select every `new` row, refresh login lists on `imported` rows, and with `--update` also `drift` rows. |
| `--only IDS` | import | Comma-separated row ids or server names. A `conflict` name needs one of its `NAME@AGENTS` ids. |
| `--dry-run` | import | Report the selection without writing. |
| `--update` | import | Allow replacing a catalog entry whose source changed (`drift`). |
| `--yes` | import | Write without the confirmation question. Required outside a terminal and with `--json`. |
| `--json` | import | Emit one `hive-mcp-import.v1` document. `login` rejects it. |
| `--agent AGENT` | login | `codex` or `claude`. Pi cannot receive granted servers; OpenCode and Grok sign-in are not supported yet. |

## Behavior

1. Discovery is read-only. Codex servers come from `codex mcp list --json` (user and trusted-project servers plus each one's login state), OpenCode from `opencode debug config`, Claude from `~/.claude.json` (`mcpServers` and `projects[<cwd>].mcpServers`) and `<cwd>/.mcp.json`, Pi from `~/.pi/agent/mcp.json` and `.pi/mcp.json`, Grok from `$GROK_HOME/config.toml`. An agent that cannot be read is skipped with a notice.
2. Each entry is converted to the catalog shape. A `${VAR}`, `{env:VAR}` or `$VAR` reference becomes `bearer_token_env`, `headers_env` or `env_from`. A literal bearer token or secret-looking header or env value is replaced by a suggested variable name that the command lists for export; the literal is never written. Values built from a shell command (`!cmd`) or a partial interpolation are refused.
3. Rows are compared with the catalog: `new`, `imported`, `drift` (URL, argv or env names changed at the source), `catalog-only` (imported earlier, now gone), `conflict` (agents disagree on one name), `refused`. Drift is never applied without `--update`.
4. OAuth servers record `oauth_logins`: the agents that hold a saved login, read by key only (Codex `auth_status`, Claude `mcpOAuth` keys, Pi `mcp-auth.json` keys). Rendering skips an OAuth server for an agent without a login and logs a `hive mcp login` hint.
5. Writes go through `Hive::Config.update_global_config!` under the global config lock and keep every other key. The new block is validated before it is written.
6. `login` runs the agent's own flow in the terminal. Codex runs `codex mcp login SERVER` with `-c mcp_servers.SERVER.url=…` (and `oauth_resource`, `--scopes`) so the saved key matches Hive's rendering. Claude runs `claude mcp login SERVER`, which finds the server in Claude's own config. On success the agent is added to the server's `oauth_logins`.
7. `hive setup` and `hive init` ask once, in a terminal, to import the `new` rows and record `mcp.import_offered: true` whatever the answer. `--yes`, `--json` and non-TTY runs skip the question.

## Examples

```
$ hive mcp import --dry-run
#   STATUS        NAME                     SOURCES                TYPE   AUTH
1   new           linear                   codex                  http   oauth
2   new           writero                  codex                  http   oauth (signed in: codex)
3   new           screenote                claude                 http   none
dry run: would import nothing
```

## JSON contract (`schema = "hive-mcp-import"`, version 1)

`hive mcp import --json` emits one document; resolve the schema with `Hive::Schemas.schema_path("hive-mcp-import")`.

```json
{
  "schema": "hive-mcp-import", "schema_version": 1, "ok": true, "action": "import",
  "dry_run": false, "catalog_path": "/home/me/.config/hive/config.yml",
  "written": ["linear"],
  "rows": [{"id": "linear", "name": "linear", "status": "new", "sources": ["codex"],
            "transport": "http", "auth": "oauth", "logins": [], "exports": [],
            "refusal": null, "selected": true}],
  "notices": ["grok skipped: /home/me/.grok/config.toml is not readable"]
}
```

`exports` lists variable names only. Rows never carry credential values.

## Errors

Failures emit the error arm: `ok: false`, `error_class`, `error_kind`, `exit_code`, `message`, and `action` when the subcommand was named. `error_kind` is one of `usage`, `consent_required` (a write without `--yes`, `--all`/`--only`, or a terminal), `config` (malformed global config), `agent` (the sign-in did not complete), `internal`. Pre-dispatch Thor rejections use the same schema with `error_kind: "usage"`. If the error document itself cannot be serialized, the command warns on stderr and re-raises the original failure.

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | Import reported or written; login recorded |
| 1 | `login`: the agent's sign-in did not complete |
| 64 | Usage error or consent required |
| 70 | Internal error |
| 78 | Malformed global config |

## Backlinks

- [[cli]] · [[modules/mcp]] · [[modules/config]] · [[commands/doctor]] · [[commands/setup]] · [[commands/init]]
