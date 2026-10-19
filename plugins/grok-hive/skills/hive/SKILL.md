---
name: hive
description: Operate the local Hive workflow engine through the Hive MCP connector. Use for current operational status, one task, routine advances, brainstorm answers, and read-only doctor checks.
---

# Hive connector

Use the Hive MCP tools. Do not shell out to `hive` for these jobs, and do not invent argv. Grok namespaces the tools as `hive__status`, `hive__task`, `hive__doctor`, `hive__answer_inventory`, `hive__answer_write`, and `hive__act`.

1. Call `status` for a fresh operational snapshot before any claim or action. Report the exact `project:slug`, state, blocker owner, and reason from that document.
2. Call `task` for one task's result, usage, or evidence. Set `log` only when the current receipt-correlated diagnostic is required.
3. Call `act` only with `action_id`, `target`, and `observation` copied from that same snapshot. Accepted action ids are `workflow.advance` and `workflow.retry`. Call `status` again after a successful act; the receipt does not prove the later pipeline state.
4. Call `answer_inventory` to list brainstorm slots. Call `answer_write` with that slot's binding and the operator's final answer. Writing an answer does not advance the task.
5. Call `doctor` for read-only health. It does not install skills or change configuration.

Daily history stays on `hive digest --json`. This connector does not refresh, send, or prune a digest, and it does not run releases, deploys, force flags, marker clears, or arbitrary commands.

The server runs in the same environment as the `hive` binary and that user's Hive state. A Grok Bot cloud computer sees Hive only when Hive is installed and configured on that computer.
