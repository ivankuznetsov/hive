## 2026-07-28: Bind nested execution to the live-authored instruction

**Action:** The OpenClaw creator proof no longer assumes that a credentialed
creator will choose one fixed sentence for the editorial research instruction.
The proof-owned Claude fixture now performs a bounded, no-follow read of the
actual authored instruction and requires the real Hive stage prompt to carry
those exact bytes. Its one-shot receipt records the instruction path, digest,
and size. Final inspection revalidates the complete authored workflow tree and
the same instruction bytes before attestation.

**Evidence:** Focused fixture, proof-runner, attestor, and verifier tests cover
the valid binding, instruction/prompt disagreement, malformed instruction
evidence, one-shot execution, and the existing credential, argv, artifact, and
descriptor safeguards. A live diagnostic reproduced the former failure with a
semantically valid model-authored instruction, demonstrating that the rejected
constant was a harness assumption rather than a Hive stage failure.

**Remaining gap:** A fresh credentialed exact-candidate run must still close the
optional live proof before this architecture unit is review-ready.
