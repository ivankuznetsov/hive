---
title: hive operation
type: command
source: lib/hive/commands/operation.rb, lib/hive/remote/dispatcher.rb, schemas/hive-operation.v1.json
created: 2026-11-07
updated: 2026-11-07
tags: [command, remote, receipt]
---

`hive operation ID --project PROJECT --context NAME [--json]` looks up one
durable remote command receipt and its linked task/attempt progress. The ID is
returned as `operation_id` in a mutation acknowledgement. The project must be
an explicit exact registration name. Local contexts fail before runtime work
with guidance to use `hive receipt` for local commands.

JSON success and pre-dispatch errors use `hive-operation.v1`. Success includes
the installation ID and a data object with `id`, `command`, `state`,
`command_outcome`, `result_available`, `result_expired`, `acknowledgement`, and
`progress`. The original command outcome and subsequent workflow progress are
separate. Accepted/queued work can remain queued when its daemon is stopped;
an expired result is reported explicitly.

Any valid token can inspect its own operation in a currently authorized
project without `read`. Other-principal access requires `read`. Expiry,
revocation and project authorization still apply on each request.

When a mutation response is lost, Hive prints `UNKNOWN SUBMISSION OUTCOME`,
the exact target and the original idempotency key. Retry the identical command
with that key to recover its acknowledgement and operation ID. The transport
does not automatically repeat a POST, generate a replacement key, or cancel
accepted work. Caller-supplied keys should have high entropy.
