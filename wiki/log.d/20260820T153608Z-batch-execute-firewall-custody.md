# Batch growing execute custody history

Execute now protects growing context-receipt and activity-operation history
with multiple bounded `ArtifactFirewall` manifests nested around the same
single implementation-agent call. Every existing receipt is still captured,
observed, and restored on tampering; the 128-entry limit remains enforced for
each manifest. The protected-anchor set rejects required-output manifests and
is capped at 16 manifests, preserving a finite snapshot stack. If custody
validation cannot produce a report, Execute leaves task-local state untouched.

A real Webmail task accumulated enough retry receipts that its first execute
launch failed before Pi started with `protected_anchors exceeds 128 entries`.
The task had valid durable history, not a malformed manifest source. New
firewall and execute regressions prove that a later batch detects and restores
a mutated receipt while the provider call is allowed to launch.
