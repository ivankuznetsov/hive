---
title: hive mcp
type: command
source: lib/hive/cli.rb, lib/hive/commands/mcp.rb, lib/hive/mcp/, plugins/grok-hive/
created: 2026-10-14
updated: 2026-10-14
tags: [command, mcp, grok, connector]
---

**TLDR**: `hive mcp` is the stdio MCP server a Grok session uses as a Hive
connector. It exposes a closed tool set over the existing command objects.
It is not a shell, and it does not move task folders on its own.

## Usage

```bash
hive mcp
hive mcp --plugin-path
grok plugin install "$(hive mcp --plugin-path)" --trust
grok mcp add hive -- hive mcp
```

Without `--plugin-path`, the process reads newline-delimited JSON-RPC from
stdin and writes replies to stdout until stdin closes. Diagnostics stay on
stderr. `--plugin-path` prints the shipped `plugins/grok-hive` directory and
exits. That directory is the Grok plugin: `plugin.json`, `.mcp.json`, and
`skills/hive/SKILL.md`. The manifest runs `hive mcp`.

The server negotiates MCP protocol versions `2025-06-18`, `2025-03-26`, and
`2024-11-05`. An unsupported client version receives `2025-06-18`.

## Tools

| Tool | Hive call | Effect |
|------|-----------|--------|
| `status` | `Hive::Commands::Status` with operational JSON | Read a fresh operational snapshot |
| `task` | `Hive::Commands::Task` | Read one semantic workspace, or the current diagnostic log when `log` is true |
| `doctor` | `Hive::Commands::Doctor` JSON | Read health. Does not install or change configuration |
| `answer_inventory` | `Hive::Commands::Answer` JSON inventory | List brainstorm slots and bindings |
| `answer_write` | `Hive::Commands::Answer` JSON write | Write one bound final answer. Does not advance the task |
| `act` | `Hive::Commands::Act` JSON | Run `workflow.advance` or `workflow.retry` with the snapshot's `project:slug` and observation token |

Grok namespaces these as `hive__status` and the matching names. Unknown
tools, extra arguments, a non-routine action id, a target that is not
`project:slug`, or an observation token that is not 64 lowercase hex
characters are rejected before a command object runs. `act` still
revalidates the token inside [[commands/status]].

A command JSON document with `"ok": false` is returned as a tool error.
Other JSON documents are successful tool results even when doctor reports
unhealthy rows. The daily digest is intentionally absent: agents keep using
`hive digest --json`, as recorded in [[gaps]].

## Placement

The process uses the Hive installation and state of the environment that
starts it. Grok Build on this machine sees this machine's Hive. A Grok Bot
cloud computer sees Hive only when that computer has Hive installed and
configured. This command does not publish an HTTP server.
