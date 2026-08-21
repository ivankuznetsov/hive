# Plan verification findings can revise automatically

Plan-review verification no longer parks policy-authorized residual findings
in `awaiting_decision` or leaves a rediscovered disposition marked
`incorporated`. A verifier-created actionable finding is persisted, any exact
approval policy is consumed immediately, prior fingerprint-bound authority is
preserved, and the daemon receives a runnable follow-up revision. Each new
planner pass starts from the latest candidate and writes a digest-named
immutable artifact; three successful revision rounds are allowed before a
repeated residual blocks.

`TaskAction` also recognizes policy-eligible legacy `awaiting_decision`
records as runnable. This lets the daemon recover a record written before the
fix without an operator replay, while manual or unmatched findings remain
operator-owned.
