## [2026-08-20T11:05:00Z] plan review - batch growing authority history under the firewall

**Action:** Partition plan-review history into bounded `ArtifactFirewall`
manifests while keeping the task-control files and required reviewer output in
their own manifest.

**Why:** A real Webmail plan accumulated 136 review records. The adapter tried
to place every record plus its core task anchors into one manifest, exceeded
the firewall's 128-entry admission bound, and returned
`protected_anchors exceeds 128 entries` before Pi launched. Growing immutable
history is normal retry evidence, not malformed reviewer input.

**Contract:** The global per-manifest bound stays unchanged. Every existing
plan-review file is still captured before the reviewer runs, observed after it
returns, and restored on tampering. Batching changes only how that exact set is
presented to the firewall; it does not omit history or widen write authority.

**Verification:** The production-runner test creates 133 historical records,
mutates the last record from inside the simulated reviewer, and proves the
reviewer launched, the later batch detected the mutation, and the original
bytes were restored. The focused adapter suite passes with 25 runs and 131
assertions; focused RuboCop is green.
