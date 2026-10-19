---
title: Add the Grok Hive MCP connector
date: 2026-10-14
---

**Added:** `hive mcp` speaks newline-delimited MCP stdio for Grok. The
shipped `plugins/grok-hive` plugin registers that command and a short
operating skill. Tools call the existing status, task, doctor, answer, and
act command objects. They do not accept arbitrary hive argv.

**Safety:** `act` accepts only `workflow.advance` and `workflow.retry`, and
only with a `project:slug` plus a 64-character observation token. Brainstorm
writes still go through the bound answer command. Digest refresh, send, and
prune stay off this surface. The server binds to the local Hive process; it
does not open a public port.

**Verified:** Focused connector tests cover protocol negotiation, the closed
tool list, argument rejection, in-process command wiring, the plugin
manifest, and the CLI `--plugin-path` switch.
