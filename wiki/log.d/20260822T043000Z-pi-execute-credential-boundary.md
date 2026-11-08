## [2026-08-22T04:30:00Z] Pi execute — keep controller publication credentials out of the agent

**Root cause:** A Pi execute agent inherited the desktop session bus. On Linux,
`gh auth token` can use that bus to retrieve the operator's stored GitHub token
from Secret Service even when the child has no `GH_*` token variable and no gh
configuration file. The agent followed a plan's publication unit, wrote a
world-readable temporary credential helper, and pushed its branch even though
remote publication belongs to Hive's later open-PR stage.

**Change:** Pi child processes now drop `DBUS_SESSION_BUS_ADDRESS` and
`SSH_AUTH_SOCK`, preserving Pi provider authentication while removing the
controller's desktop credential transports. The execute prompt now explicitly
forbids pushes and PR mutations and names 5-open-pr as their owner.

**Coverage:** Agent environment tests pin both transport variables absent for
Pi, and the execute-template contract test pins the controller-owned
publication instruction.

**Verified:** focused agent and execute-template tests.

**Links:** [[stages/execute]] · [[stages/open-pr]] · [[modules/agent_profile]]
