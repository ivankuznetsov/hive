## 2026-08-05 — Workflow Creator live proof review hardening

**Change:** Final review moved candidate homes, the Git directory, and OpenClaw
state/config/approvals into an owner-private control root outside the model-
writable workspace; U14's socket now lives in the owner-private workspace
parent. The gateway checks Git/skill
identity before every candidate command, and the runner checks the complete
OpenClaw control plane around both model loops.
The existing U14 gateway/execution pair budget moved narrowly from 600 to 615
lines to retain the external socket, injected boundary verifier, and semantic
status check without compressed lifecycle code or a seventh runtime owner.

**Evidence:** A passing primary now retains validated native
`openclaw skills info hive --json` evidence and accepts the final operational
status only when it names exactly the created editorial task at `1-research`.
Bootstrap failures replace only the initial `preflight/not_started` receipt;
more specific typed failures remain unchanged.

**Authorization:** The live workflow requires the repository owner as both the
dispatching and triggering actor, refuses rerun attempts, and repeats that gate
inside every credential-bearing job before provider secrets are exposed.

**Proof:** The post-review focused checkpoint passed 117 runs and 4,176
assertions with zero failures, errors, or skips. Thirteen changed Ruby files
passed RuboCop, both changed YAML contracts parsed, and the diff whitespace and
literal-secret scans passed. The optional hostile suite was not run.
