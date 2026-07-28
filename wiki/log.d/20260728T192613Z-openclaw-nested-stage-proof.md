## 2026-07-28: Bind the OpenClaw creator's nested stage execution

**Action:** The workflow-creator proof now safe-loads and binds the exact
accepted editorial descriptor, including project-level agent/model inheritance.
Its first task run reaches a proof-owned, credential-free Claude fixture outside
the workspace. That one-shot fixture accepts only the expected inherited
research-stage argv and bounded prompt, writes deterministic nonempty
`research.md` bytes ending in one trailing completion marker, and records
fixture, prompt, argv, task, and before/after artifact identities. The inspector,
attestor, and verifier all bind those records and reject semantic descriptor,
fixture, or artifact drift. Candidate audit failures now retain a bounded
structured failure receipt instead of raw stderr.

**Evidence:** Focused proof-runner, attestation/verifier, and process-architecture
tests cover exact success, provider-credential rejection, prompt/argv drift,
one-shot enforcement, fixture replacement/removal, malformed or semantically
drifted descriptors, completed-artifact mutation, and structured candidate
failure evidence. The fixture proves nested-stage routing and completion; it is
not represented as a remote Claude model invocation.

**Remaining gap:** The operator-controlled credentialed protected-main
`live-workflow-creator` run remains required before this optional diagnostic has
trusted hosted attestation.
