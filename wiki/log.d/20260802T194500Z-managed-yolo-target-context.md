## [2026-08-02T19:45:00Z] workflows/agent - expose the declared target to managed yolo actors

**Action:** Managed generic agents and council reviewers/revisers now pass the owning project root through the runtime-policy base context. The managed `yolo` compiler preserves those validated roots as explicit runner add-dirs, while portable non-yolo actors retain their read-only projection and ordinary brainstorm/plan stages remain task-only.

**Why:** A live Root Cause Repair run reached diagnosis but Codex refused the repair because its explicit workspace roots contained only the task and immutable workflow package. The descriptor already granted unbounded `yolo` authority over the target; omitting the project from runner context made that declared contract unusable for target mutation.

**Evidence:** Focused runtime-policy, generic-agent, and council tests assert the project/task/package context across all mutating and reviewing actor paths. The external workflow acceptance rerun remains the end-to-end gate.
