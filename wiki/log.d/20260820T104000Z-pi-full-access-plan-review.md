## [2026-08-20T10:40:00Z] plan review - let Pi use the approved full-access review boundary

**Action:** Removed the managed-workflow wrapper from Pi plan-review launches.
That wrapper is intentionally read-only and rejected the required `Bash` tool,
so every Pi review failed before model invocation with `runner :pi cannot
enforce managed tools ["Bash"]`. Pi reviewers now run through the native agent
path, receive the repository root explicitly in the review prompt, and write
the ordinary adapter result file in the disposable review directory.

**Boundary:** Plan review continues to protect the immutable plan copy, task
metadata, and review authority records with `Hive::ArtifactFirewall`. Codex and
Grok keep their native workspace-write sandboxes and Claude keeps exact
file-tool scope. Pi uses detection and restore because its managed bubblewrap
route cannot provide the repo, shell, and network access required for a real
review.

**Verification:** Focused workspace-scope and document-review adapter tests pin
the unrestricted Pi launch contract, explicit repository-root prompt, direct
result-file output, and retained result validation.
