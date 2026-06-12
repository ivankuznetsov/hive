# ce-code-review round 2 — 7 findings fixed (PR #300)

- P1: compose.example.yml + docker README now bind 127.0.0.1 (claimable
  box must not face the LAN pre-claim).
- hive-dispatch-request v2: requestor enum gains "healer"; queue
  SCHEMA_VERSION bumped per the schema's own coordinated-upgrade protocol.
- hive-drop.v2.json $id/title fixed; new schema-identity test ties
  filename ↔ $id ↔ title ↔ SCHEMA_VERSIONS for every exported schema.
- Telegram setup strictly parses chat IDs (422 on blank/@handle input)
  before any network call or save.
- Repos clone refuses a pre-existing non-directory target; clone! never
  rm_rf's a path it didn't create.
- /health?deep=1 verifies the daemon via its pidfile (PidFile ownership
  semantics); Dockerfile HEALTHCHECK uses it.
- Task diff is bounded: own process group, 15s deadline, 512KB cap with
  a truncation notice.

Dogfood note: leaked sandbox daemons (tests/E2E spawning `hive daemon
start` without teardown, surviving via detach) can sweep-kill foreign
processes — six were found and stopped on the dev machine. Gap filed.
