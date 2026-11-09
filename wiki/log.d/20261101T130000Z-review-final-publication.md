# 2026-11-01 — Retained final review fixes and archive recovery

- Archive blockers retain owned path/branch, persisted PR head and full omitted
  fix SHAs in optional typed details. Missing PR references are explicitly unknown.
- Publication references must match the owned path, branch and recorded local
  head; strict schema validation preserves full commit identifiers.
- Preserved delivered-head ancestry and merge-tree content-equivalence checks;
  a follow-up PR that delivered the content still permits archive.
- One formatter carries full details through web/CLI preview and all three
  archive errors. Nothing pushes to or readies an already-merged PR.
- Verified operator-committed final-stale fixes can pass guardrails and publish
  for immutable retry without fake fix-success receipts or extra repair grants.
- CI diagnostics retain their actual head; older-head success is pending on the
  new review head. Configured-out gates are explicitly skipped.
- Finalize-side review-head validation remains an open, out-of-scope backstop.
- Review also pins the Git gate's local branch resolution to the admitted OID;
  concurrent replacement commits cannot publish. Terminal stale/error paths
  recheck PR identity/head without another push, and approval-receipt restarts
  still owe their commits a reviewer pass.
