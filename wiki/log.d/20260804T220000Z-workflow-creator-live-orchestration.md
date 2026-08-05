## 2026-08-04 — Workflow Creator live orchestration boundary

**Change:** Added the U15 `WorkflowCreatorLiveSetup` and
`WorkflowCreatorLiveRunner` boundary above U14. Setup admits exact candidate and
OpenClaw artifacts, immutable installed runtimes, the candidate `/hive`
projection, one private initialized workspace, and the effective SQLite-backed
OpenClaw execution policy. The runner owns selected-provider credential routing,
the two vocabulary-fixed OpenClaw model loops, observed graph/task/effect truth,
and U1b primary finalization.

**Security:** Only the credential selected by the exact model prefix reaches the
outer OpenClaw processes. The configured shell strips both provider credentials
and GitHub/Git/SSH authority before model-invoked tools, and U14 remains the sole
gateway and process-custody owner. Dependency, transport, runtime, policy, and
workspace drift fail with typed non-passing evidence.

**Workflow:** The smoke and GitHub workflow are thin adapters. The committed
`openclaw@2026.7.2-beta.7` / Node `22.23.1` lock is installed with lifecycle
scripts disabled, production dependencies are audited, and evidence is
initialized before setup so failures remain uploadable. The U14 private
shebang gateway is now owner-executable so OpenClaw can invoke its allowlisted
path without widening ownership. Hostile suites and authenticated provider
calls remain optional rather than part of normal pull-request CI.

**Proof:** The focused checkpoint passed 137 runs / 1,994 assertions with only
the expected credential-gated skip. A credential-free installed probe used the
real beta7 runtime, authenticated the SQLite policy, stopped before model
execution, retained typed non-passing evidence, and removed its workspace.

**Limit:** A passing live claim still requires an explicitly authorized run on
the unchanged exact head. Local deterministic proof and ordinary hosted CI do
not replace that artifact.
