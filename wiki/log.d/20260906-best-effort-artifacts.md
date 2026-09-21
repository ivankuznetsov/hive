## Best-effort automatic artifact collection

`Stages::Artifacts.run!` keeps trying the existing collector, but records an
explicit completion warning when capture, provider, capability, or evidence
validation fails. It preserves diagnostics and files, never fabricates an
accepted package, and does not repeat failed collection after completion.
Source identity/custody failures and implementation-rework findings still
block. Focused regressions cover missing capture receipts, provider limits,
blocked capture, idempotent resume, and retained integrity/rework failures.
The larger capture/Screenote redesign remains deferred in `wiki/gaps.md`.
