# PR #1148 round-two autonomy fixes

Round-two review exposed six integration gaps after the broader Pi/provider
recovery work landed:

- deterministic-recovery parks were cleared by the next scheduler resume;
- Codex planner revisions had lost the Git-checkout boundary they require;
- the three-round verification cap could be bypassed through a new
  orchestration entry;
- strict status schemas omitted emitted blocker and route diagnostics;
- corrupt plan-review progress projections could raise during attempt
  generation; and
- dotted literal values under prefixed password names escaped the review-fix
  guardrail.

The recovery coordinator now preserves a deterministic park across scheduler
ticks and uses the existing freshness-bound `workflow.retry` action as the
explicit unpark after remediation. Review and planner-revision agents share one
detached disposable Git-worktree implementation, and the verification cap is
checked on every entry. Both status schemas describe the emitted recovery
fields, plan-review progress corruption degrades to a stable unreadable token,
and password assignment detection covers conventional prefixes without
mistaking a dot in a literal value for a runtime lookup.

Focused regression coverage proves three parked ticks consume no child spawn or
daily slot, explicit retry resumes the same request, Codex receives a real Git
checkout, capped external re-entry remains capped, real operational-status
projection validates with the new fields, malformed progress bytes stay
bounded, and a prefixed password with a dotted literal value is reported.

A later simplification review removed five redundant seams before delivery:
unreachable host-output/host-anchor prompt branches and Pi anchor rewriting,
the tautological workspace-support predicate, AutoCommit's private duplicate
secret scanner and unused path argument, Hive's second provider-error rescue,
and byte-identical recovery-reset construction in the orchestrator and decision
service. Existing component/profile and end-to-end tests retain the behavior at
the single remaining owners.
