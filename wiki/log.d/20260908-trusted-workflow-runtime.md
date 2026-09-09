## Run trusted packages like ordinary agents

Explicit `yolo` managed actors retain their ordinary environment, including
installed tool and provider configuration, instead of receiving a reduced
environment. Existing direct execution already avoids the scoped sandbox and
host-owned JSON output adapter. Regression coverage checks direct execution,
unrestricted tool selection, and inherited environment for Claude, Codex, Grok,
Pi, and OpenCode. Restricted package policies remain unchanged.
